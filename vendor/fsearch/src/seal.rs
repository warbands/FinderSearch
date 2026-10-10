//! Encryption at rest for the index files (a FinderSearch addition). Once a
//! key is set (`fsearch app` gets one from the app), the name index and the
//! content segments are sealed with AES-256-GCM on disk and decrypted into
//! memory on load. Without a key, files are written and mapped as before.
//!
//! Format: `FSSEAL01`, the plaintext length (u64 LE), an 8-byte random nonce
//! prefix, then the plaintext in 1 MiB chunks, each as ciphertext + 16-byte
//! tag. Chunk i's nonce is the prefix + i (u32 BE), and every chunk's
//! associated data is the file's name plus that header: chunks can't be
//! reordered, dropped or moved to another file, and a damaged, truncated or
//! foreign file fails to open (the engine then rebuilds it).

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{AeadInOut, KeyInit, Nonce, Tag};
use memmap2::{Mmap, MmapMut};
use rayon::prelude::*;
use std::fs::File;
use std::io::{BufWriter, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

const MAGIC: &[u8; 8] = b"FSSEAL01";
const HEAD: usize = 24;
const CHUNK: usize = 1 << 20;
const TAG: usize = 16;

static KEY: OnceLock<Aes256Gcm> = OnceLock::new();

/// Seal every index file from now on. Set once, before the engine starts.
pub fn set_key(key: &[u8; 32]) {
    let _ = KEY.set(Aes256Gcm::new(key.into()));
}

/// The name a file is sealed under: its final name, not the temp file's.
pub fn name(path: &Path) -> String {
    path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned())
}

/// Chunks a plaintext of `len` bytes is sealed in; empty still takes one,
/// so its tag authenticates the header.
fn chunks(len: usize) -> usize {
    len.div_ceil(CHUNK).max(1)
}

fn header(len: u64, prefix: &[u8; 8]) -> [u8; HEAD] {
    let mut h = [0u8; HEAD];
    h[..8].copy_from_slice(MAGIC);
    h[8..16].copy_from_slice(&len.to_le_bytes());
    h[16..].copy_from_slice(prefix);
    h
}

fn parse(head: &[u8]) -> Option<(usize, [u8; 8])> {
    if head.len() < HEAD || &head[..8] != MAGIC {
        return None;
    }
    let len = usize::try_from(u64::from_le_bytes(head[8..16].try_into().ok()?)).ok()?;
    Some((len, head[16..HEAD].try_into().ok()?))
}

fn aad(name: &str, head: &[u8]) -> Vec<u8> {
    [name.as_bytes(), &[0], &head[..HEAD]].concat()
}

fn nonce(prefix: &[u8; 8], i: usize) -> Nonce<Aes256Gcm> {
    let mut n = [0u8; 12];
    n[..8].copy_from_slice(prefix);
    n[8..].copy_from_slice(&(i as u32).to_be_bytes());
    n.into()
}

fn open_chunk(cipher: &Aes256Gcm, prefix: &[u8; 8], aad: &[u8], i: usize, data: &mut [u8], tag: &[u8]) -> bool {
    let Ok(tag) = Tag::<Aes256Gcm>::try_from(tag) else { return false };
    cipher.decrypt_inout_detached(&nonce(prefix, i), aad, data.into(), &tag).is_ok()
}

/// Writes a file `len` bytes long, sealed when a key is set. `finish`
/// completes it.
pub struct Writer {
    out: BufWriter<File>,
    seal: Option<Sealer>,
}

struct Sealer {
    cipher: &'static Aes256Gcm,
    prefix: [u8; 8],
    aad: Vec<u8>,
    buf: Vec<u8>,
    chunks: usize,
    len: u64,
    written: u64,
}

impl Sealer {
    fn seal_chunk(&mut self, out: &mut impl Write) -> std::io::Result<()> {
        let tag = self
            .cipher
            .encrypt_inout_detached(&nonce(&self.prefix, self.chunks), &self.aad, self.buf.as_mut_slice().into())
            .map_err(|_| std::io::Error::other("seal failed"))?;
        out.write_all(&self.buf)?;
        out.write_all(&tag)?;
        self.buf.clear();
        self.chunks += 1;
        Ok(())
    }
}

impl Writer {
    pub fn create(path: &Path, name: &str, len: usize) -> std::io::Result<Writer> {
        Writer::with(KEY.get(), path, name, len)
    }

    fn with(key: Option<&'static Aes256Gcm>, path: &Path, name: &str, len: usize) -> std::io::Result<Writer> {
        let mut out = BufWriter::with_capacity(CHUNK + TAG, File::create(path)?);
        let seal = match key {
            None => None,
            Some(cipher) => {
                let mut prefix = [0u8; 8];
                unsafe { libc::arc4random_buf(prefix.as_mut_ptr().cast(), prefix.len()) };
                let head = header(len as u64, &prefix);
                out.write_all(&head)?;
                Some(Sealer { cipher, prefix, aad: aad(name, &head), buf: Vec::with_capacity(CHUNK), chunks: 0, len: len as u64, written: 0 })
            }
        };
        Ok(Writer { out, seal })
    }

    pub fn finish(mut self) -> std::io::Result<File> {
        if let Some(s) = &mut self.seal {
            if s.written != s.len {
                return Err(std::io::Error::other(format!("sealed {} bytes, expected {}", s.written, s.len)));
            }
            if !s.buf.is_empty() || s.chunks == 0 {
                s.seal_chunk(&mut self.out)?;
            }
        }
        self.out.into_inner().map_err(|e| e.into_error())
    }
}

impl Write for Writer {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        let Some(s) = &mut self.seal else { return self.out.write(data) };
        let n = data.len().min(CHUNK - s.buf.len());
        s.buf.extend_from_slice(&data[..n]);
        s.written += n as u64;
        if s.buf.len() == CHUNK {
            s.seal_chunk(&mut self.out)?;
        }
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.out.flush()
    }
}

/// Map a file `Writer` wrote: decrypted into memory when a key is set, else
/// mapped as is. None if it's missing, empty, from the other mode, or fails to
/// authenticate (another key, damaged, tampered). Small files: `read`.
pub fn open(path: &Path, name: &str) -> Option<Mmap> {
    open_with(KEY.get(), path, name)
}

fn open_with(key: Option<&Aes256Gcm>, path: &Path, name: &str) -> Option<Mmap> {
    let map = unsafe { Mmap::map(&File::open(path).ok()?) }.ok()?;
    let Some(cipher) = key else { return (!map.starts_with(MAGIC)).then_some(map) };
    let (len, prefix) = parse(&map)?;
    if len == 0 || map.len() != HEAD + len + chunks(len) * TAG {
        return None;
    }
    let aad = aad(name, &map);
    let mut out = MmapMut::map_anon(len).ok()?;
    let ok = out.par_chunks_mut(CHUNK).enumerate().all(|(i, dst)| {
        let at = HEAD + i * (CHUNK + TAG);
        dst.copy_from_slice(&map[at..at + dst.len()]);
        open_chunk(cipher, &prefix, &aad, i, dst, &map[at + dst.len()..at + dst.len() + TAG])
    });
    if ok { out.make_read_only().ok() } else { None }
}

/// A file `Writer` wrote, readable a range at a time: `ensure` a range, then
/// read it through `as_ptr`. Sealed files are decrypted a chunk at a time on
/// first use, into anonymous memory the kernel backs only once written, so
/// the parts never read cost no memory. Every chunk's tag is still checked
/// when the file is opened: a damaged or foreign file is refused up front.
pub enum Bytes {
    Plain(Mmap),
    Lazy(Lazy),
}

pub struct Lazy {
    file: Mmap,
    /// Owns the plaintext buffer `base` points into.
    _out: MmapMut,
    base: *mut u8,
    len: usize,
    ready: Vec<AtomicBool>,
    lock: Mutex<()>,
    cipher: &'static Aes256Gcm,
    prefix: [u8; 8],
    aad: Vec<u8>,
}

// `base` is only written by `decrypt`, one chunk once under `lock`, before
// `ready` publishes it; readers only read chunks `ready` has published.
unsafe impl Send for Lazy {}
unsafe impl Sync for Lazy {}

impl Bytes {
    pub fn len(&self) -> usize {
        match self {
            Bytes::Plain(m) => m.len(),
            Bytes::Lazy(l) => l.len,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn as_ptr(&self) -> *const u8 {
        match self {
            Bytes::Plain(m) => m.as_ptr(),
            Bytes::Lazy(l) => l.base,
        }
    }

    /// Make `start..start + n` readable.
    #[inline]
    pub fn ensure(&self, start: usize, n: usize) {
        if let Bytes::Lazy(l) = self
            && n > 0
        {
            for i in start / CHUNK..=(start + n - 1) / CHUNK {
                if !l.ready[i].load(Ordering::Acquire) {
                    l.decrypt(i);
                }
            }
        }
    }

    /// `start..start + n`, made readable first.
    pub fn range(&self, start: usize, n: usize) -> &[u8] {
        assert!(start + n <= self.len());
        self.ensure(start, n);
        unsafe { std::slice::from_raw_parts(self.as_ptr().add(start), n) }
    }
}

impl Lazy {
    #[cold]
    fn decrypt(&self, i: usize) {
        let _one = self.lock.lock().unwrap();
        if self.ready[i].load(Ordering::Relaxed) {
            return;
        }
        let (at, n) = (HEAD + i * (CHUNK + TAG), (self.len - i * CHUNK).min(CHUNK));
        // This chunk's bytes, written once before `ready` says so; no reader
        // looks at them until then, and other chunks are disjoint.
        let dst = unsafe { std::slice::from_raw_parts_mut(self.base.add(i * CHUNK), n) };
        dst.copy_from_slice(&self.file[at..at + n]);
        // Checked when opened: failing now means the file changed under us.
        assert!(open_chunk(self.cipher, &self.prefix, &self.aad, i, dst, &self.file[at + n..at + n + TAG]), "sealed file changed while open");
        self.ready[i].store(true, Ordering::Release);
    }
}

/// Open a file `Writer` wrote for reading a range at a time (see `Bytes`).
/// None as for `open`.
pub fn open_lazy(path: &Path, name: &str) -> Option<Bytes> {
    open_lazy_with(KEY.get(), path, name)
}

fn open_lazy_with(key: Option<&'static Aes256Gcm>, path: &Path, name: &str) -> Option<Bytes> {
    let Some(cipher) = key else { return open_with(None, path, name).map(Bytes::Plain) };
    let file = unsafe { Mmap::map(&File::open(path).ok()?) }.ok()?;
    let (len, prefix) = parse(&file)?;
    if len == 0 || file.len() != HEAD + len + chunks(len) * TAG {
        return None;
    }
    let aad = aad(name, &file);
    let ok = (0..chunks(len)).into_par_iter().all(|i| {
        let (at, n) = (HEAD + i * (CHUNK + TAG), (len - i * CHUNK).min(CHUNK));
        let mut scratch = file[at..at + n].to_vec();
        open_chunk(cipher, &prefix, &aad, i, &mut scratch, &file[at + n..at + n + TAG])
    });
    let mut out = MmapMut::map_anon(len).ok()?;
    let base = out.as_mut_ptr();
    let ready = (0..chunks(len)).map(|_| AtomicBool::new(false)).collect();
    ok.then(|| Bytes::Lazy(Lazy { file, _out: out, base, len, ready, lock: Mutex::new(()), cipher, prefix, aad }))
}

/// Write a small file whole, sealed when a key is set.
pub fn write(path: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    write_with(KEY.get(), path, name, bytes)
}

fn write_with(key: Option<&'static Aes256Gcm>, path: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    let mut w = Writer::with(key, path, name, bytes.len())?;
    w.write_all(bytes)?;
    w.finish().map(drop)
}

/// Read a small file `write` wrote, empty included. None as for `open`.
pub fn read(path: &Path, name: &str) -> Option<Vec<u8>> {
    read_with(KEY.get(), path, name)
}

fn read_with(key: Option<&Aes256Gcm>, path: &Path, name: &str) -> Option<Vec<u8>> {
    let b = std::fs::read(path).ok()?;
    let Some(cipher) = key else { return (!b.starts_with(MAGIC)).then_some(b) };
    let (len, prefix) = parse(&b)?;
    if b.len() != HEAD + len + chunks(len) * TAG {
        return None;
    }
    let aad = aad(name, &b);
    let mut out = Vec::with_capacity(len);
    for i in 0..chunks(len) {
        let at = HEAD + i * (CHUNK + TAG);
        let n = (len - i * CHUNK).min(CHUNK);
        let mut chunk = b[at..at + n].to_vec();
        if !open_chunk(cipher, &prefix, &aad, i, &mut chunk, &b[at + n..at + n + TAG]) {
            return None;
        }
        out.extend_from_slice(&chunk);
    }
    Some(out)
}

/// The first `n` bytes of a file `Writer` wrote (n ≤ 1 MiB), decrypting only
/// its first chunk.
pub fn read_prefix(path: &Path, name: &str, n: usize) -> Option<Vec<u8>> {
    read_prefix_with(KEY.get(), path, name, n)
}

fn read_prefix_with(key: Option<&Aes256Gcm>, path: &Path, name: &str, n: usize) -> Option<Vec<u8>> {
    let mut f = File::open(path).ok()?;
    let Some(cipher) = key else {
        let mut b = vec![0; n];
        f.read_exact(&mut b).ok()?;
        return (!b.starts_with(MAGIC)).then_some(b);
    };
    let mut head = [0u8; HEAD];
    f.read_exact(&mut head).ok()?;
    let (len, prefix) = parse(&head)?;
    let first = len.min(CHUNK);
    if n > first {
        return None;
    }
    let mut buf = vec![0; first + TAG];
    f.read_exact(&mut buf).ok()?;
    let (data, tag) = buf.split_at_mut(first);
    open_chunk(cipher, &prefix, &aad(name, &head), 0, data, tag).then(|| data[..n].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cipher(byte: u8) -> &'static Aes256Gcm {
        Box::leak(Box::new(Aes256Gcm::new(&[byte; 32].into())))
    }

    /// A scratch folder, removed when dropped.
    struct Dir(std::path::PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    impl std::ops::Deref for Dir {
        type Target = Path;
        fn deref(&self) -> &Path {
            &self.0
        }
    }

    fn dir() -> Dir {
        let d = std::env::temp_dir().join(format!("fsearch-seal-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&d).unwrap();
        Dir(d)
    }

    fn data(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    fn write(key: Option<&'static Aes256Gcm>, path: &Path, name: &str, bytes: &[u8]) {
        let mut w = Writer::with(key, path, name, bytes.len()).unwrap();
        // Uneven writes, to cross chunk boundaries mid-write.
        for part in bytes.chunks(333_333) {
            w.write_all(part).unwrap();
        }
        w.finish().unwrap();
    }

    #[test]
    fn round_trips_across_chunk_sizes() {
        let (k, d) = (cipher(1), dir());
        for len in [1, 100, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK + 12_345] {
            let p = d.join("index.bin");
            write(Some(k), &p, "index.bin", &data(len));
            assert_eq!(std::fs::metadata(&p).unwrap().len() as usize, HEAD + len + len.div_ceil(CHUNK) * TAG);
            assert_eq!(&open_with(Some(k), &p, "index.bin").unwrap()[..], &data(len)[..], "len {len}");
            assert_eq!(read_prefix_with(Some(k), &p, "index.bin", 1).unwrap(), data(1));
        }
    }

    #[test]
    fn plaintext_never_reaches_disk() {
        let (k, d) = (cipher(2), dir());
        let p = d.join("seg-000001.fsc");
        let secret = b"/Users/someone/Documents/private-diagnosis.pdf".repeat(1000);
        write(Some(k), &p, "seg-000001.fsc", &secret);
        let disk = std::fs::read(&p).unwrap();
        assert!(!disk.windows(20).any(|w| w == &secret[..20]));
    }

    #[test]
    fn rejects_wrong_key_name_tampering_and_truncation() {
        let (k, d) = (cipher(3), dir());
        let p = d.join("index.bin");
        write(Some(k), &p, "index.bin", &data(2 * CHUNK + 7));
        assert!(open_with(Some(cipher(4)), &p, "index.bin").is_none(), "another key");
        assert!(open_with(Some(k), &p, "seg-000001.fsc").is_none(), "another file's name");
        assert!(read_prefix_with(Some(cipher(4)), &p, "index.bin", 8).is_none());

        let good = std::fs::read(&p).unwrap();
        let mut bad = good.clone();
        bad[HEAD + CHUNK + TAG + 5] ^= 1; // a byte in the second chunk
        std::fs::write(&p, &bad).unwrap();
        assert!(open_with(Some(k), &p, "index.bin").is_none(), "tampered");

        std::fs::write(&p, &good[..good.len() - 1]).unwrap();
        assert!(open_with(Some(k), &p, "index.bin").is_none(), "truncated");

        let mut swapped = good.clone(); // chunks 0 and 1 exchanged
        let (a, b) = (HEAD, HEAD + CHUNK + TAG);
        swapped[a..b].copy_from_slice(&good[b..b + CHUNK + TAG]);
        swapped[b..b + CHUNK + TAG].copy_from_slice(&good[a..b]);
        std::fs::write(&p, &swapped).unwrap();
        assert!(open_with(Some(k), &p, "index.bin").is_none(), "reordered");
    }

    #[test]
    fn modes_dont_read_each_others_files() {
        let (k, d) = (cipher(5), dir());
        let (sealed, plain) = (d.join("sealed"), d.join("plain"));
        write(Some(k), &sealed, "sealed", &data(1000));
        write(None, &plain, "plain", &data(1000));
        assert!(open_with(None, &sealed, "sealed").is_none());
        assert!(open_with(Some(k), &plain, "plain").is_none());
        assert_eq!(&open_with(None, &plain, "plain").unwrap()[..], &data(1000)[..]);
    }

    #[test]
    fn small_files_round_trip_even_empty() {
        let (k, d) = (cipher(7), dir());
        let p = d.join("skipped");
        for bytes in [&b""[..], b"/Users/someone/Library/Mail\n"] {
            write_with(Some(k), &p, "skipped", bytes).unwrap();
            assert_eq!(read_with(Some(k), &p, "skipped").unwrap(), bytes);
            assert!(read_with(Some(cipher(8)), &p, "skipped").is_none());
        }
        let mut bad = std::fs::read(&p).unwrap();
        bad[HEAD] ^= 1;
        std::fs::write(&p, &bad).unwrap();
        assert!(read_with(Some(k), &p, "skipped").is_none());
    }

    #[test]
    fn lazy_reads_match_and_refuse_what_open_refuses() {
        let (k, d) = (cipher(9), dir());
        let p = d.join("seg-000002.fsc");
        let bytes = data(3 * CHUNK + 777);
        write(Some(k), &p, "seg-000002.fsc", &bytes);
        let Some(b @ Bytes::Lazy(_)) = open_lazy_with(Some(k), &p, "seg-000002.fsc") else { panic!("not lazy") };
        // Ranges inside one chunk, across a boundary, the tail, and the whole.
        for (start, n) in [(5, 10), (CHUNK - 3, 9), (3 * CHUNK + 700, 77), (0, bytes.len())] {
            assert_eq!(b.range(start, n), &bytes[start..start + n]);
        }
        assert!(open_lazy_with(Some(cipher(10)), &p, "seg-000002.fsc").is_none(), "another key");
        assert!(open_lazy_with(Some(k), &p, "seg-000003.fsc").is_none(), "another file's name");
        let mut bad = std::fs::read(&p).unwrap();
        bad[HEAD + 2 * (CHUNK + TAG) + 1] ^= 1; // a chunk no range above was in yet
        std::fs::write(&p, &bad).unwrap();
        assert!(open_lazy_with(Some(k), &p, "seg-000002.fsc").is_none(), "tampered, even where unread");
    }

    #[test]
    fn lazy_decrypts_only_what_is_read() {
        let (k, d) = (cipher(11), dir());
        let p = d.join("big");
        write(Some(k), &p, "big", &data(8 * CHUNK));
        let Some(Bytes::Lazy(l)) = open_lazy_with(Some(k), &p, "big") else { panic!("not lazy") };
        let b = Bytes::Lazy(l);
        b.range(CHUNK + 10, 20);
        let Bytes::Lazy(l) = &b else { unreachable!() };
        let done: Vec<bool> = l.ready.iter().map(|r| r.load(Ordering::Relaxed)).collect();
        assert_eq!(done, [false, true, false, false, false, false, false, false]);
    }

    #[test]
    fn writer_refuses_a_short_file() {
        let (k, d) = (cipher(6), dir());
        let mut w = Writer::with(Some(k), &d.join("short"), "short", 10).unwrap();
        w.write_all(&[1; 9]).unwrap();
        assert!(w.finish().is_err());
    }
}
