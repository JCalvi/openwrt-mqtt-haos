#!/bin/sh
# Validate v1.2.6 child PID cleanup without MQTT or a router.
set -eu
HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

awk '/^case "\$1" in$/ { exit } { print }' "$HERE/../openwrt_mqtt.sh" > "$WORK/functions.sh"
. "$WORK/functions.sh"

# Verify unrelated processes are not recognized as this router's daemon.
SCRIPT="/root/openwrt_mqtt.sh"
if is_our_daemon_pid "$$" || is_our_availability_pid "$$"; then
  echo "FAIL: cleanup matched an unrelated process" >&2
  exit 1
fi

# Exercise tracked children and FIFO cleanup.
sleep 60 &
PRODUCER_PID=$!
sleep 60 &
MQTT_PID=$!
sleep 60 &
RETRY_SLEEP_PID=$!
SESSION_FIFO="$WORK/session.fifo"
mkfifo "$SESSION_FIFO"
CHILD_PIDS="$PRODUCER_PID $MQTT_PID $RETRY_SLEEP_PID"

stop_session

for PID in $CHILD_PIDS; do
  if kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: child process $PID still running" >&2
    exit 1
  fi
done
[ -z "$PRODUCER_PID$MQTT_PID$RETRY_SLEEP_PID" ] || { echo "FAIL: PID variables not cleared" >&2; exit 1; }
[ ! -e "$WORK/session.fifo" ] || { echo "FAIL: FIFO remains" >&2; exit 1; }

# Exercise the actual /proc matcher and automatic orphan sweep using a
# harmless fake daemon. The command line has the same shape as OpenWrt's
# /bin/sh /root/openwrt_mqtt.sh daemon, but uses a unique temporary path.
SCRIPT="$WORK/fake_openwrt_mqtt.sh"
WAIT_FIFO="$WORK/wait.fifo"
mkfifo "$WAIT_FIFO"
cat > "$SCRIPT" <<'SH'
#!/bin/sh
# Wait at a FIFO open without spawning any child processes.
read -r ignored < "$2"
SH
chmod +x "$SCRIPT"
"$SCRIPT" daemon "$WAIT_FIFO" &
ORPHAN_PID=$!
sleep 1
is_our_daemon_pid "$ORPHAN_PID" || {
  kill -KILL "$ORPHAN_PID" 2>/dev/null || true
  echo "FAIL: failed to identify orphaned daemon" >&2
  exit 1
}
load_config() { BASE="openwrt/unique-test-device"; }
cleanup_orphans
wait "$ORPHAN_PID" 2>/dev/null || true
if kill -0 "$ORPHAN_PID" 2>/dev/null; then
  echo "FAIL: orphaned daemon still running" >&2
  exit 1
fi

echo "PASS: unrelated-process protection, tracked-child/FIFO cleanup and orphan sweep"
