import subprocess
import os
import sys

os.chdir(r"D:\Project\Scope\ZZ\STO\trunk\v1x\program\arm\RemotePlay-iOS")

# Run git push with output captured
print("=== git push origin main ===", flush=True)
result = subprocess.run(
    ["git", "push", "origin", "main"],
    capture_output=True, text=True, timeout=60
)
print(f"EXIT: {result.returncode}", flush=True)
print(f"STDOUT: {result.stdout}", flush=True)
print(f"STDERR: {result.stderr}", flush=True)

# Verify remote
print("\n=== git rev-parse origin/main ===", flush=True)
result = subprocess.run(
    ["git", "rev-parse", "origin/main"],
    capture_output=True, text=True, timeout=10
)
print(f"REMOTE: {result.stdout.strip()}", flush=True)

print("\n=== git rev-parse main ===", flush=True)
result = subprocess.run(
    ["git", "rev-parse", "main"],
    capture_output=True, text=True, timeout=10
)
print(f"LOCAL: {result.stdout.strip()}", flush=True)
