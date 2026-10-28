#!/bin/sh
# Regression tests for per-topic MQTT change detection in OpenWrt MQTT v1.2.5.
# No OpenWrt router or broker required: pub() is mocked.
set -eu

HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT="${HERE}/../openwrt_mqtt.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# Source only function definitions; never run the script's CLI entry point.
awk '/^case "\\$1" in$/ { exit } { print }' "$SCRIPT" > "$WORK/functions.sh"
. "$WORK/functions.sh"

STATE_HASH_FILE="$WORK/state.hash"
SSID_HASH_DIR="$WORK/ssid_hashes"
BASE="openwrt/test"
STATE='{"healthy":true,"clients_total":3}'
SSID_STATE='main|Main|24|wlan0|2
second|Second|5|wlan1|1'
LOG="$WORK/messages"
FAIL_TOPIC=""

# Preserve the same pub() contract but record which MQTT topics were attempted.
pub() {
  TOPIC=""
  PREV=""
  for ARG in "$@"; do
    [ "$PREV" = "-t" ] && TOPIC="$ARG"
    PREV="$ARG"
  done
  [ "$TOPIC" = "$FAIL_TOPIC" ] && return 1
  printf '%s\n' "$TOPIC" >> "$LOG"
}

assert_count() {
  COUNT="$(wc -l < "$LOG")"
  if [ "$COUNT" -ne "$1" ]; then
    echo "FAIL: expected $1 MQTT messages, got $COUNT" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

# First publication sends the main state and both SSIDs.
publish_state
assert_count 3

# No change means no MQTT connection/publication.
publish_state
assert_count 3

# Changing one SSID does not republish the others or the main state.
SSID_STATE='main|Main|24|wlan0|3
second|Second|5|wlan1|1'
publish_state
assert_count 4
[ "$(tail -1 "$LOG")" = "openwrt/test/ssid/main/state" ]

# Changing only the total client count publishes only the main state.
STATE='{"healthy":true,"clients_total":4}'
publish_state
assert_count 5
[ "$(tail -1 "$LOG")" = "openwrt/test/state" ]

# A failed SSID publish must not update its cache; retry must succeed later.
SSID_STATE='main|Main|24|wlan0|3
second|Second|5|wlan1|2'
FAIL_TOPIC="openwrt/test/ssid/second/state"
if publish_state; then
  echo "FAIL: expected simulated MQTT failure" >&2
  exit 1
fi
assert_count 5
FAIL_TOPIC=""
publish_state
assert_count 6
[ "$(tail -1 "$LOG")" = "openwrt/test/ssid/second/state" ]

# Clear caches as do_daemon_session does after a connection loss.
rm -f "$STATE_HASH_FILE"
rm -rf "$SSID_HASH_DIR"
publish_state
assert_count 9

echo "PASS: initial publish, unchanged values, per-SSID change, retry and reconnect"
