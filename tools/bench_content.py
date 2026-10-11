"""Memory and content-search speed of one engine on one index.

usage: python3 -I tools/bench_content.py ENGINE INDEX_DIR KEY_FILE [--build]
  ENGINE     an fsearch binary (e.g. dist/FinderSearch.app/Contents/Helpers/fsearch)
  INDEX_DIR  a scratch index folder; with --build it's built first (indexes your disk
             with this terminal's permissions, so delete it afterwards)
  KEY_FILE   64 hex digits (openssl rand -hex 32 > key)

Prints JSON: load time, memory at rest / after searches / peak, name-search time,
and per query the first-run and median-of-10 times. To compare two engines, build
once, then run each on the same INDEX_DIR alternately, at least twice.
"""
import json, re, statistics, subprocess, sys, time

eng, d, key = sys.argv[1], sys.argv[2], open(sys.argv[3]).read().strip()
build = "--build" in sys.argv
p = subprocess.Popen([eng, "app"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"dir": d, "key": key}) + "\n"); p.stdin.flush()
n = 0

def ask(**r):
    global n
    n += 1
    p.stdin.write(json.dumps({"id": n, **r}) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())

def footprint():
    out = subprocess.run(["footprint", str(p.pid)], capture_output=True, text=True).stdout
    conv = lambda m: float(m[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}.get(m[2], 1) if m else 0.0
    return conv(re.search(r"phys_footprint:\s+([\d.]+)\s+(\w+)", out)), conv(re.search(r"phys_footprint_peak:\s+([\d.]+)\s+(\w+)", out))

t = time.time()
while not (s := ask(op="status"))["ok"]:
    time.sleep(0.05)
ready = time.time() - t
last, stable = None, 0
while stable < (6 if build else 3):  # let content indexing settle
    s = ask(op="status"); cur = (s["content_docs"], s["content_pending"])
    stable = stable + 1 if cur == last and s["content_pending"] == 0 else 0
    last = cur; time.sleep(1)
time.sleep(2)
idle, _ = footprint()
QUERIES = [("literal", "fn main"), ("literal", "TODO"), ("literal", "import SwiftUI"), ("literal", "the"),
           ("literal", "zq-no-such-text-8812"), ("regex", r"func \w+Engine"), ("regex", r"[A-Z]{3}_[A-Z]{4}_\d+")]
rows = []
for mode, pat in QUERIES:
    t0 = time.time(); r = ask(op="grep", pattern=pat, mode=mode); cold = (time.time() - t0) * 1000
    warm = []
    for _ in range(10):
        t0 = time.time(); r = ask(op="grep", pattern=pat, mode=mode); warm.append((time.time() - t0) * 1000)
    rows.append({"q": f"{mode}:{pat}", "first_ms": round(cold, 1), "median_ms": round(statistics.median(warm), 1), "files": len(r.get("files") or [])})
t0 = time.time(); ask(q="engine swift", limit=500); name_ms = (time.time() - t0) * 1000
after, peak = footprint()
p.stdin.close(); p.wait(15)
print(json.dumps({"ready_s": round(ready, 2), "entries": s["entries"], "content_docs": s["content_docs"],
                  "content_mb": round(s["content_bytes"] / 1048576), "mb_at_rest": round(idle), "mb_after_searches": round(after),
                  "mb_peak": round(peak), "name_search_ms": round(name_ms, 1), "queries": rows}, indent=1))
