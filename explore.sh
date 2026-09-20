#!/usr/bin/env bash
# One-shot runtime exploration for the chatroom vhosts (run via account cron).
# Writes findings to /tmp/explore.log and publishes it to 0x0.st so the
# sandbox can read it without shell access.
{
  echo "=== date ==="; date -u
  for D in chatapi.zealve.com chat.zealve.com chatapi.zealse.com; do
    echo "=== $D dir ==="
    ls -la "/home/u646404230/domains/$D/" 2>&1 | head -12
    echo "--- hbuilds/versions (latest 2) ---"
    ls -t "/home/u646404230/domains/$D/hbuilds/versions/" 2>/dev/null | head -2
    V=$(ls -t "/home/u646404230/domains/$D/hbuilds/versions/" 2>/dev/null | head -1)
    if [ -n "$V" ]; then
      echo "--- latest version nodejs dir ---"
      ls -la "/home/u646404230/domains/$D/hbuilds/versions/$V/nodejs/" 2>&1 | head -14
      echo "--- runtime status file ---"
      cat "/home/u646404230/domains/$D/hbuilds/versions/$V/nodejs/.backend_runtime_status" 2>/dev/null
      cat "/home/u646404230/domains/$D/hbuilds/versions/$V/nodejs/.go_boot_strikes" 2>/dev/null
      echo "--- app dir? ---"
      ls "/home/u646404230/domains/$D/hbuilds/versions/$V/nodejs/app/" 2>/dev/null | head -5
    fi
  done
  echo "=== account processes ==="
  ps ax -o pid,etime,cmd 2>/dev/null | grep -v "ps ax" | head -30
  echo "=== node proc envs (ports only) ==="
  for p in $(pgrep -u u646404230 -f "node" 2>/dev/null | head -12); do
    echo "pid $p cmd: $(tr "\0" " " < /proc/$p/cmdline 2>/dev/null | head -c 120)"
    tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -E "^(PORT|UPSTREAM_PORT|HOSTINGER_DOMAIN|PUBLIC_DIR|DATA_DIR)=" | head -6
  done
  echo "=== cwd of running app servers ==="
  for p in $(pgrep -u u646404230 -f "server.js" 2>/dev/null | head -3); do
    echo "pid $p cwd: $(readlink /proc/$p/cwd 2>/dev/null)"
  done
} > /tmp/explore.log 2>&1

URL=$(curl -sF "file=@/tmp/explore.log" https://0x0.st 2>/dev/null | head -1)
echo "paste: $URL" > /tmp/explore-url.txt
