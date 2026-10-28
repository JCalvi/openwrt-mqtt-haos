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

echo "PASS: unrelated-process protection and tracked-child/FIFO cleanup"
