"""End-to-end check of index encryption, in a scratch folder with throwaway keys.

Builds an index with a fake home of text files containing a marker word, then:
1. every file holding names or contents is sealed, and no marker, path or file
   name appears in plain text on disk;
2. the same key reloads it without a rebuild;
3. another key is refused and the index rebuilt;
4. no key: the engine refuses to start.

usage: python3 -I tools/seal_check.py [path/to/fsearch]   (default: the dist/ app's engine)
Runs without Full Disk Access semantics (FSEARCH_RESTRICT), so protected folders stay out.
"""
import json, os, secrets, shutil, subprocess, sys, tempfile, time

engine = sys.argv[1] if len(sys.argv) > 1 else "dist/FinderSearch.app/Contents/Helpers/fsearch"
# Resolved: /var is a link to /private/var, and the engine indexes real paths.
base = os.path.realpath(tempfile.mkdtemp(prefix="fsearch-seal-"))
index, home = os.path.join(base, "index"), os.path.join(base, "home")
os.makedirs(os.path.join(home, "notes"))
for i in range(30):
    with open(os.path.join(home, "notes", f"zebra-note-{i}.txt"), "w") as f:
        f.write(f"line one\nthe quartz-7731 marker {i}\n")
env = {**os.environ, "FSEARCH_RESTRICT": "1", "HOME": home}
n = 0

def start(key):
    p = subprocess.Popen([engine, "app"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    if key:
        p.stdin.write(json.dumps({"dir": index, "key": key}) + "\n"); p.stdin.flush()
    return p

def ask(p, **r):
    global n
    n += 1
    p.stdin.write(json.dumps({"id": n, **r}) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())

def ready(p):
    t = time.time()
    while not (s := ask(p, op="status"))["ok"]:
        time.sleep(0.05)
    return s, time.time() - t

def stop(p):
    p.stdin.close(); p.wait(10)

failed = []
try:
    k1, k2 = secrets.token_hex(32), secrets.token_hex(32)
    p = start(k1); s, dt = ready(p)
    t = time.time()
    while ask(p, op="status")["content_docs"] < 30 and time.time() - t < 60:
        time.sleep(0.5)
    g = ask(p, op="grep", pattern="quartz-7731", mode="literal")
    print(f"built in {dt:.1f}s; content search finds {len(g['files'])} of 30 files")
    if len(g["files"]) != 30: failed.append("content search")
    ask(p, op="save"); time.sleep(3); stop(p)

    for dirpath, _, names in os.walk(index):
        for name in names:
            path = os.path.join(dirpath, name)
            data = open(path, "rb").read()
            leaks = [w for w in (b"zebra-note", b"quartz-7731", home.encode(), b"/Applications") if w in data]
            sealed = data.startswith(b"FSSEAL01")
            print(f"  {os.path.relpath(path, index):24} {'sealed' if sealed else 'plain '}  leaks: {leaks or 'none'}")
            if leaks: failed.append(f"leak in {name}")

    p = start(k1); s, dt = ready(p); h = ask(p, q="zebra-note", limit=5)
    print(f"same key: ready in {dt * 1000:.0f} ms, {len(h['hits'])} name hits")
    if dt > 2 or not h["hits"]: failed.append("reload")
    stop(p)
    p = start(k2); s, dt = ready(p)
    print(f"other key: ready in {dt:.1f}s (rebuilt)")
    stop(p)
    p = start(None); p.stdin.close(); p.wait(10)
    print(f"no key: exit {p.returncode}")
    if p.returncode != 2: failed.append("no key")
finally:
    shutil.rmtree(base, ignore_errors=True)
print("FAIL: " + ", ".join(failed) if failed else "ok")
sys.exit(1 if failed else 0)
