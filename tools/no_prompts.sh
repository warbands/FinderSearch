#!/bin/zsh
# Proves FinderSearch never looks inside a folder macOS guards with a consent
# prompt (Desktop, Documents, Downloads) while it lacks Full Disk Access, in
# $HOME or any other home under /Users (an old home keeps its guarded folders).
#
# Runs under a sandbox that kills the process on any read inside those folders
# and hides the privacy database, so FinderSearch believes it has no Full Disk
# Access. Nothing appears on screen from the engine test; the app test opens a
# window for ~15 s. Neither touches the real index or the Keychain: the engine
# test uses a scratch index, and in the app test the engine may not start.
#
# usage: tools/no_prompts.sh [path/to/FinderSearch.app]   (default: dist/FinderSearch.app)
set -uo pipefail
app="${1:-dist/FinderSearch.app}"
engine="$app/Contents/Helpers/fsearch"
[[ -x "$engine" ]] || { print -u2 "No engine at $engine; build first (scripts/build.sh)."; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

homes=("$HOME" /Users/*(N/))
alts="${(j:|:)homes}"
cat > "$tmp/kill.sb" <<EOF
(version 1)
(allow default)
(deny file-read-data (with send-signal SIGKILL) (regex #"^($alts)/(Desktop|Documents|Downloads)(/|\$)"))
(deny file-read-xattr (with send-signal SIGKILL) (regex #"^($alts)/(Desktop|Documents|Downloads)/"))
(deny file-read-data (literal "/Library/Application Support/com.apple.TCC/TCC.db"))
(deny mach-lookup (global-name "com.apple.SecurityServer"))
EOF
# The app test checks the window only: its engine is the engine test's job, and
# started here it would rebuild the real index under a throwaway key.
cp "$tmp/kill.sb" "$tmp/app.sb"
print "(deny process-exec (literal \"${engine:A}\"))" >> "$tmp/app.sb"
print "Guarded folders under: ${(j:, :)homes}"

# Engine: 45 s covers the full scan and the start of content indexing.
python3 -I - "$engine" "$tmp/index" "$tmp/kill.sb" <<'EOF'
import json, secrets, subprocess, sys, time
engine, index, profile = sys.argv[1:]
p = subprocess.Popen(["sandbox-exec", "-f", profile, engine, "app"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)
p.stdin.write(json.dumps({"dir": index, "key": secrets.token_hex(32)}) + "\n"); p.stdin.flush()
t = time.time()
while time.time() - t < 45 and p.poll() is None:
    time.sleep(0.5)
if p.poll() is not None:
    print(f"engine: FAIL, killed after {time.time() - t:.1f}s for reading a guarded folder"); sys.exit(1)
p.stdin.close(); p.wait(10)
print("engine: ok, ran 45 s without reading a guarded folder")
EOF
engine_ok=$?

# App: opens a window on the home folder (icons drawn for Desktop etc.).
sandbox-exec -f "$tmp/app.sb" "$app/Contents/MacOS/FinderSearch" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
for i in {1..15}; do sleep 1; kill -0 $pid 2>/dev/null || break; done
if kill -0 $pid 2>/dev/null; then
    print "app: ok, ran 15 s without reading a guarded folder"; kill $pid; wait $pid 2>/dev/null; app_ok=0
else
    wait $pid; print "app: FAIL, killed after ${i}s for reading a guarded folder"; app_ok=1
fi
exit $(( engine_ok || app_ok ))
