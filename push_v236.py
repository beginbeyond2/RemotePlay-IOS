import subprocess
import os

LOG = r"D:\Project\Scope\ZZ\STO\trunk\v1x\program\arm\RemotePlay-iOS\push_log_v236.txt"

def log(msg):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(msg + "\n")
        f.flush()
    print(msg, flush=True)

with open(LOG, "w", encoding="utf-8") as f:
    f.write("")

os.chdir(r"D:\Project\Scope\ZZ\STO\trunk\v1x\program\arm\RemotePlay-iOS")
log(f"cwd: {os.getcwd()}")

# git add
log("=== git add . ===")
r = subprocess.run(["git", "add", "."], capture_output=True, text=True, timeout=10)
log(f"add exit: {r.returncode}")
log(f"add stderr: {r.stderr}")

# git commit
log("=== git commit ===")
msg = "fix(decoder): v2.3.6 - use static let with @convention(c) for VT callback"
r = subprocess.run(
    ["git", "commit", "-m", msg],
    capture_output=True, text=True, timeout=10
)
log(f"commit exit: {r.returncode}")
log(f"commit stdout: {r.stdout}")
log(f"commit stderr: {r.stderr}")

# pull --rebase
log("=== git pull --rebase --autostash ===")
r = subprocess.run(
    ["git", "pull", "--rebase", "--autostash", "origin", "main"],
    capture_output=True, text=True, timeout=60
)
log(f"pull exit: {r.returncode}")
log(f"pull stdout: {r.stdout}")
log(f"pull stderr: {r.stderr}")

# push
log("=== git push ===")
r = subprocess.run(
    ["git", "push", "origin", "main"],
    capture_output=True, text=True, timeout=120
)
log(f"push exit: {r.returncode}")
log(f"push stdout: {r.stdout}")
log(f"push stderr: {r.stderr}")

# verify
r = subprocess.run(["git", "rev-parse", "main"], capture_output=True, text=True, timeout=10)
log(f"LOCAL: {r.stdout.strip()}")
r = subprocess.run(["git", "rev-parse", "origin/main"], capture_output=True, text=True, timeout=10)
log(f"REMOTE: {r.stdout.strip()}")
log("DONE")
