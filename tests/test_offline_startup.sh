#!/usr/bin/env bash
# When kernel.org does not answer, startup (even --help) used to wait for
# 3 lookups x 4 attempts x 20s (~4.3 minutes). It must now give up quickly
# and still run. "Does not answer" is simulated with a local proxy that
# accepts connections and never replies, which stalls curl the same way on
# every network.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
limit=40
work=$(mktemp -d)
python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(64)
print(s.getsockname()[1], flush=True)
conns = []
while True:
    c, _ = s.accept(); conns.append(c)   # accept, never answer
' > "$work/port" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
port=$(cat "$work/port")
fail=0

start=$(date +%s)
out=$(cd "$REPO" && https_proxy="http://127.0.0.1:$port" HTTPS_PROXY="http://127.0.0.1:$port" \
  no_proxy='' NO_PROXY='' timeout 90 bash ./kernel_installer.sh --help 2>&1)
rc=$?
took=$(( $(date +%s) - start ))

if [ "$rc" -eq 124 ]; then
  echo "FAIL: --help was still waiting for kernel.org after 90s"
  fail=1
elif [ "$took" -ge "$limit" ]; then
  echo "FAIL: --help took ${took}s with kernel.org unreachable (limit ${limit}s)"
  fail=1
else
  echo "ok: --help took ${took}s with kernel.org unreachable"
fi
if [ "$rc" -ne 124 ] && ! grep -q -- '--kernel' <<<"$out"; then
  echo "FAIL: --help output missing"
  fail=1
fi
exit "$fail"
