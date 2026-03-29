"""
Smart index update for OpenViking.
Only re-indexes when source files have changed since the last index run.
"""
import subprocess
import sys
import os
import socket

GIT_DIR        = r"C:\Dev\Stellar_studio"
SRC_DIR        = r"C:\Dev\Stellar_studio\app\src"
OV_EXE         = r"C:\Users\andre\Anaconda3\envs\openviking\Scripts\ov.exe"
LAST_COMMIT_FILE = r"C:\Dev\stellar-bot\.last-indexed-commit"
OPENVIKING_PORT  = 1933
SOURCE_EXTS      = {".js", ".jsx", ".ts", ".tsx", ".css", ".md"}

def banner(msg):
    print(f"\n{'='*50}\n  {msg}\n{'='*50}")

def check_openviking():
    try:
        s = socket.create_connection(("127.0.0.1", OPENVIKING_PORT), timeout=2)
        s.close()
        return True
    except OSError:
        return False

def git(args):
    result = subprocess.run(
        ["git"] + args,
        cwd=GIT_DIR,
        capture_output=True,
        text=True
    )
    return result.stdout.strip()

def ov(args, silent=False):
    result = subprocess.run(
        [OV_EXE] + args,
        capture_output=True,
        text=True
    )
    if not silent and result.stdout:
        print(result.stdout.strip())
    return result.stdout.strip()

def get_source_files():
    files = []
    for root, _, filenames in os.walk(SRC_DIR):
        for f in filenames:
            if os.path.splitext(f)[1] in SOURCE_EXTS:
                files.append(os.path.join(root, f))
    return files

def get_changed_files(last_commit, current_commit):
    output = git(["diff", "--name-only", last_commit, current_commit])
    if not output:
        return []
    changed = []
    for line in output.splitlines():
        ext = os.path.splitext(line)[1]
        if ext in SOURCE_EXTS and line.startswith("app/src"):
            changed.append(line)
    return changed

def read_last_commit():
    if os.path.exists(LAST_COMMIT_FILE):
        with open(LAST_COMMIT_FILE) as f:
            return f.read().strip()
    return None

def save_last_commit(commit):
    with open(LAST_COMMIT_FILE, "w") as f:
        f.write(commit)

def clear_index():
    print("  Clearing existing resources...")
    listing = ov(["ls", "viking://resources/"], silent=True)
    removed = 0
    for line in listing.splitlines():
        if "upload_" in line:
            parts = line.strip().split("/")
            for part in parts:
                if part.startswith("upload_"):
                    ov(["rm", f"viking://resources/{part}"], silent=True)
                    removed += 1
                    break
    print(f"  Removed {removed} existing resources.")

def reindex_all(source_files):
    print(f"  Indexing {len(source_files)} source files...")
    for i, f in enumerate(source_files, 1):
        name = os.path.basename(f)
        print(f"  [{i}/{len(source_files)}] {name}")
        ov(["add-resource", f], silent=True)
    print("\n  Waiting for indexing to complete...")
    ov(["system", "wait", "--timeout", "300"])

# ── Main ─────────────────────────────────────────────────────────────────────

banner("Smart Index Update — Stellar Studio")

# 1. Check OpenViking
if not check_openviking():
    print("  ERROR: OpenViking is not running on port 1933.")
    print("  Start it first with start-openviking.bat")
    sys.exit(1)
print("  OpenViking is running.")

# 2. Get current commit
current_commit = git(["rev-parse", "HEAD"])
if not current_commit:
    print("  ERROR: Could not read git HEAD.")
    sys.exit(1)
print(f"  Current commit : {current_commit[:12]}")

# 3. Compare with last indexed
last_commit = read_last_commit()

if last_commit == current_commit:
    print("  Index is already up to date with HEAD.")
    print("  No re-index needed.")
    print("\n  To force a full re-index, delete .last-indexed-commit and re-run.")
    sys.exit(0)

if last_commit:
    print(f"  Last indexed   : {last_commit[:12]}")
else:
    print("  No previous index found — will do full index.")

# 4. Check what changed
if last_commit:
    changed = get_changed_files(last_commit, current_commit)
    if changed:
        print(f"\n  {len(changed)} source file(s) changed:")
        for f in changed:
            print(f"    {f}")
    else:
        print("\n  No source files changed since last index.")
        print("  Updating commit marker.")
        save_last_commit(current_commit)
        sys.exit(0)

# 5. Re-index
print()
source_files = get_source_files()
clear_index()
print()
reindex_all(source_files)

# 6. Save new baseline
save_last_commit(current_commit)

print(f"\n  Done! {len(source_files)} files indexed.")
print(f"  Commit {current_commit[:12]} saved as index baseline.")
