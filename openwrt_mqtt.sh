#!/bin/sh
#
# OpenWrt WiFi MQTT Publisher for Home Assistant
# Version: 1.2.3
#
# Commands:
#   /root/openwrt_mqtt.sh install
#   /root/openwrt_mqtt.sh discovery
#   /root/openwrt_mqtt.sh publish
#   /root/openwrt_mqtt.sh daemon
#   /root/openwrt_mqtt.sh all
#   /root/openwrt_mqtt.sh status
#   /root/openwrt_mqtt.sh version
#   /root/openwrt_mqtt.sh install-service  # non-interactive migration
#
# Required package:
#   apk add mosquitto-client-nossl
#
# Config:
#   /etc/config/openwrt_mqtt
#
# Service:
#   /etc/init.d/openwrt_mqtt
#

VERSION="1.2.3"
CONFIG="openwrt_mqtt"
SCRIPT="/root/openwrt_mqtt.sh"
SERVICE="/etc/init.d/openwrt_mqtt"

STATE_HASH_FILE="/tmp/openwrt_mqtt_state.hash"
SLOW_HASH_FILE="/tmp/openwrt_mqtt_slow.hash"
HEARTBEAT_FILE="/tmp/openwrt_mqtt_heartbeat"

safe_id() {
  printf '%s' "$1" | awk '{print tolower($0)}' | sed 's/[^abcdefghijklmnopqrstuvwxyz0123456789]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

prompt() {
  PROMPT_VAR="$1"
  PROMPT_MSG="$2"
  PROMPT_DEFAULT="$3"

  printf '%s [%s]: ' "$PROMPT_MSG" "$PROMPT_DEFAULT"
  read -r PROMPT_INPUT
  [ -z "$PROMPT_INPUT" ] && PROMPT_INPUT="$PROMPT_DEFAULT"
  eval "$PROMPT_VAR=\"\$PROMPT_INPUT\""
}

load_config() {
  MQTT_HOST="$(uci -q get ${CONFIG}.@mqtt[0].host)"
  MQTT_USER="$(uci -q get ${CONFIG}.@mqtt[0].user)"
  MQTT_PASS="$(uci -q get ${CONFIG}.@mqtt[0].password)"
  DISC="$(uci -q get ${CONFIG}.@mqtt[0].discovery_prefix)"
  HEARTBEAT_SECONDS="$(uci -q get ${CONFIG}.@mqtt[0].heartbeat)"
  POLL_SECONDS="$(uci -q get ${CONFIG}.@mqtt[0].poll_interval)"

  [ -z "$MQTT_HOST" ]         && MQTT_HOST="192.168.1.20"
  [ -z "$MQTT_USER" ]         && MQTT_USER="openwrt"
  [ -z "$MQTT_PASS" ]         && MQTT_PASS=""
  [ -z "$DISC" ]              && DISC="homeassistant"
  [ -z "$HEARTBEAT_SECONDS" ] && HEARTBEAT_SECONDS=300
  [ -z "$POLL_SECONDS" ]      && POLL_SECONDS=60

  HOSTNAME="$(uci -q get system.@system[0].hostname)"
  [ -z "$HOSTNAME" ] && HOSTNAME="openwrt"

  DEVICE_ID="$(safe_id "$HOSTNAME")"
  BASE="openwrt/${DEVICE_ID}"

  MODEL="$(cat /tmp/sysinfo/model 2>/dev/null)"
  [ -z "$MODEL" ] && MODEL="OpenWrt"

  FW="$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_DESCRIPTION")"

  DEVICE="\"device\":{\"identifiers\":[\"openwrt_${DEVICE_ID}\"],\"name\":\"$(json_escape "$HOSTNAME")\",\"manufacturer\":\"OpenWrt\",\"model\":\"$(json_escape "$MODEL")\",\"sw_version\":\"$(json_escape "$FW")\"}"
}

check_requirements() {
  command -v mosquitto_pub >/dev/null 2>&1 || {
    echo "Missing mosquitto_pub. Install with: apk add mosquitto-client-nossl"
    exit 1
  }

  command -v iw >/dev/null 2>&1 || {
    echo "Missing iw."
    exit 1
  }

  command -v uci >/dev/null 2>&1 || {
    echo "Missing uci."
    exit 1
  }
}

pub() {
  mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" "$@"
}

publish_sensor() {
  NAME="$1"
  UID="$2"
  TOPIC="$3"
  TEMPLATE="$4"
  EXTRA="$5"

  pub -r -t "${DISC}/sensor/${UID}/config" \
    -m "{\"name\":\"${NAME}\",\"unique_id\":\"${UID}\",\"state_topic\":\"${TOPIC}\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"${TEMPLATE}\",${EXTRA}${DEVICE}}"
}

publish_binary_sensor() {
  NAME="$1"
  UID="$2"
  TOPIC="$3"
  TEMPLATE="$4"

  pub -r -t "${DISC}/binary_sensor/${UID}/config" \
    -m "{\"name\":\"${NAME}\",\"unique_id\":\"${UID}\",\"state_topic\":\"${TOPIC}\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"${TEMPLATE}\",\"payload_on\":\"true\",\"payload_off\":\"false\",\"device_class\":\"connectivity\",${DEVICE}}"
}

wifi_list() {
  iw dev | awk '
    /Interface/ { iface=$2 }
    /^[[:space:]]*ssid / { ssid=$2 }
    /^[[:space:]]*channel / {
      freq=$3
      gsub(/[^0-9]/, "", freq)
      band = (freq < 3000) ? "24" : "5"
      print iface "|" ssid "|" band
    }
  '
}

create_config() {
  echo ""
  echo "--- MQTT Configuration ---"

  EXISTING_HOST="$(uci -q get ${CONFIG}.@mqtt[0].host)"
  EXISTING_USER="$(uci -q get ${CONFIG}.@mqtt[0].user)"
  EXISTING_PASS="$(uci -q get ${CONFIG}.@mqtt[0].password)"
  EXISTING_DISC="$(uci -q get ${CONFIG}.@mqtt[0].discovery_prefix)"
  EXISTING_HEARTBEAT="$(uci -q get ${CONFIG}.@mqtt[0].heartbeat)"
  EXISTING_POLL="$(uci -q get ${CONFIG}.@mqtt[0].poll_interval)"

  [ -z "$EXISTING_HOST" ]      && EXISTING_HOST="192.168.1.20"
  [ -z "$EXISTING_USER" ]      && EXISTING_USER="openwrt"
  [ -z "$EXISTING_PASS" ]      && EXISTING_PASS=""
  [ -z "$EXISTING_DISC" ]      && EXISTING_DISC="homeassistant"
  [ -z "$EXISTING_HEARTBEAT" ] && EXISTING_HEARTBEAT="300"
  [ -z "$EXISTING_POLL" ]      && EXISTING_POLL="60"

  prompt CFG_HOST      "MQTT host"               "$EXISTING_HOST"
  prompt CFG_USER      "MQTT user"               "$EXISTING_USER"
  prompt CFG_PASS      "MQTT password"           "$EXISTING_PASS"
  prompt CFG_DISC      "Discovery prefix"        "$EXISTING_DISC"
  prompt CFG_POLL      "Poll interval (seconds, for clients/WiFi up)" "$EXISTING_POLL"
  prompt CFG_HEARTBEAT "Heartbeat (seconds, for uptime/load/temp/memory)" "$EXISTING_HEARTBEAT"

  if [ ! -f /etc/config/openwrt_mqtt ]; then
    cat > /etc/config/openwrt_mqtt <<CFG
config mqtt
        option host ''
        option user ''
        option password ''
        option discovery_prefix ''
        option poll_interval ''
        option heartbeat ''
CFG
  fi

  uci set ${CONFIG}.@mqtt[0].host="$CFG_HOST"
  uci set ${CONFIG}.@mqtt[0].user="$CFG_USER"
  uci set ${CONFIG}.@mqtt[0].password="$CFG_PASS"
  uci set ${CONFIG}.@mqtt[0].discovery_prefix="$CFG_DISC"
  uci set ${CONFIG}.@mqtt[0].poll_interval="$CFG_POLL"
  uci set ${CONFIG}.@mqtt[0].heartbeat="$CFG_HEARTBEAT"
  uci commit ${CONFIG}

  echo ""
  echo "Config saved to /etc/config/openwrt_mqtt"
}

# Preserve our configuration and service files across OpenWrt sysupgrade.
# Idempotent: retain existing entries/comments and never append duplicates.
ensure_sysupgrade_config() {
  KEEP_FILE="/etc/sysupgrade.conf"
  if [ ! -e "$KEEP_FILE" ]; then
    : > "$KEEP_FILE" || return 1
  fi
  if [ ! -f "$KEEP_FILE" ]; then
    echo "Cannot update $KEEP_FILE: not a regular file" >&2
    return 1
  fi
  for KEEP_PATH in \
    /root/openwrt_mqtt.sh \
    /etc/config/openwrt_mqtt \
    /etc/init.d/openwrt_mqtt \
    /etc/rc.local
  do
    if ! grep -Fqx "$KEEP_PATH" "$KEEP_FILE"; then
      printf '%s\n' "$KEEP_PATH" >> "$KEEP_FILE" || return 1
    fi
  done
  echo "Verified sysupgrade preservation entries: $KEEP_FILE"
}

create_service() {
  cat > "$SERVICE" <<'SVC'
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

start_service() {
        procd_open_instance
        procd_set_param command /root/openwrt_mqtt.sh daemon
        # Retry indefinitely after unexpected failures.
        procd_set_param respawn 3600 5 0
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}

stop_service() {
        # procd stops may close the persistent publisher cleanly (no MQTT LWT).
        # Explicitly mark the device offline before stopping it.
        [ -z "$IPKG_INSTROOT" ] && /root/openwrt_mqtt.sh offline >/dev/null 2>&1 || true
}
SVC

  chmod +x "$SERVICE"
  "$SERVICE" enable >/dev/null 2>&1
  ensure_sysupgrade_config || return 1
  echo "Installed service: $SERVICE"
}

# Keep MQTT discovery failures visible to the daemon so it retries after a
# late-starting broker instead of leaving missing or stale HA entities.
discovery_pub() {
  if ! pub "$@"; then
    DISCOVERY_FAILED=1
    return 1
  fi
}

do_discovery() {
  load_config
  check_requirements
  DISCOVERY_FAILED=0

  UPTIME_TEMPLATE="{% set s = value_json.uptime | int %}{% if s < 3600 %}{{ s // 60 }}m {{ s % 60 }}s{% elif s < 86400 %}{{ s // 3600 }}h {{ s % 3600 // 60 }}m{% else %}{{ s // 86400 }}d {{ s % 86400 // 3600 }}h{% endif %}"

  discovery_pub -r -t "${DISC}/binary_sensor/${DEVICE_ID}_healthy/config" -m "{\"name\":\"WiFi Healthy\",\"unique_id\":\"${DEVICE_ID}_wifi_healthy\",\"state_topic\":\"${BASE}/state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ iif(value_json.healthy, 'true', 'false') }}\",\"payload_on\":\"true\",\"payload_off\":\"false\",\"device_class\":\"connectivity\",${DEVICE}}"

  discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_clients_total/config" -m "{\"name\":\"Total Clients\",\"unique_id\":\"${DEVICE_ID}_clients_total\",\"state_topic\":\"${BASE}/state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ value_json.clients_total }}\",\"state_class\":\"measurement\",${DEVICE}}"

  discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_cpu_temp/config" -m "{\"name\":\"CPU Temperature\",\"unique_id\":\"${DEVICE_ID}_cpu_temp\",\"state_topic\":\"${BASE}/slow_state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ value_json.cpu_temp }}\",\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\"state_class\":\"measurement\",${DEVICE}}"

  discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_memory/config" -m "{\"name\":\"Memory Used\",\"unique_id\":\"${DEVICE_ID}_memory_used\",\"state_topic\":\"${BASE}/slow_state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ value_json.memory_used_pct }}\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",${DEVICE}}"

  discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_load1/config" -m "{\"name\":\"Load 1m\",\"unique_id\":\"${DEVICE_ID}_load1\",\"state_topic\":\"${BASE}/slow_state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ value_json.load1 }}\",${DEVICE}}"

  discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_uptime/config" -m "{\"name\":\"Uptime\",\"unique_id\":\"${DEVICE_ID}_uptime\",\"state_topic\":\"${BASE}/slow_state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"$(json_escape "$UPTIME_TEMPLATE")\",\"icon\":\"mdi:timer-outline\",${DEVICE}}"

  if ! wifi_list | while IFS='|' read -r IFACE SSID BAND; do
    [ -z "$IFACE" ] && continue
    [ -z "$SSID" ] && continue

    [ "$BAND" = "24" ] && BAND_NAME="2.4 GHz" || BAND_NAME="5 GHz"

    SSID_ID="$(safe_id "${SSID}-${BAND}")"
    SSID_NAME="$(json_escape "$SSID")"

    discovery_pub -r -t "${DISC}/binary_sensor/${DEVICE_ID}_${SSID_ID}_up/config" -m "{\"name\":\"${SSID_NAME} ${BAND_NAME} Up\",\"unique_id\":\"${DEVICE_ID}_${SSID_ID}_up\",\"state_topic\":\"${BASE}/ssid/${SSID_ID}/state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ iif(value_json.up, 'true', 'false') }}\",\"payload_on\":\"true\",\"payload_off\":\"false\",\"device_class\":\"connectivity\",${DEVICE}}" || exit 1

    discovery_pub -r -t "${DISC}/sensor/${DEVICE_ID}_${SSID_ID}_clients/config" -m "{\"name\":\"${SSID_NAME} ${BAND_NAME} Clients\",\"unique_id\":\"${DEVICE_ID}_${SSID_ID}_clients\",\"state_topic\":\"${BASE}/ssid/${SSID_ID}/state\",\"availability_topic\":\"${BASE}/availability\",\"value_template\":\"{{ value_json.clients }}\",\"state_class\":\"measurement\",${DEVICE}}" || exit 1
  done; then
    DISCOVERY_FAILED=1
  fi

  [ "$DISCOVERY_FAILED" -eq 0 ]
}

build_state() {
  TOTAL_CLIENTS="$(iw dev | awk '/Interface/ {print $2}' | while read -r IFACE; do iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station'; done | awk '{s+=$1} END {print s+0}')"

  STATE="{\"healthy\":true,\"clients_total\":${TOTAL_CLIENTS}}"

  SSID_STATE="$(
    wifi_list | while IFS='|' read -r IFACE SSID BAND; do
      [ -z "$IFACE" ] && continue
      [ -z "$SSID" ] && continue
      SSID_ID="$(safe_id "${SSID}-${BAND}")"
      CLIENTS="$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')"
      echo "${SSID_ID}|${SSID}|${BAND}|${IFACE}|${CLIENTS}"
    done
  )"
}

build_slow_state() {
  UPTIME="$(cut -d. -f1 /proc/uptime)"
  LOAD1="$(awk '{print $1}' /proc/loadavg)"

  MEM_TOTAL="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  MEM_AVAILABLE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

  if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ]; then
    MEM_USED_PCT="$(( (MEM_TOTAL - MEM_AVAILABLE) * 100 / MEM_TOTAL ))"
  else
    MEM_USED_PCT=0
  fi

  TEMP_RAW="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
  [ -n "$TEMP_RAW" ] && CPU_TEMP="$((TEMP_RAW / 1000))" || CPU_TEMP=0

  SLOW_STATE="{\"uptime\":${UPTIME},\"load1\":\"${LOAD1}\",\"memory_used_pct\":${MEM_USED_PCT},\"cpu_temp\":${CPU_TEMP}}"
}

publish_state() {
  FAILED=0
  pub -r -t "${BASE}/state" -m "$STATE" || FAILED=1

  printf '%s\n' "$SSID_STATE" | while IFS='|' read -r SSID_ID SSID BAND IFACE CLIENTS; do
    [ -z "$SSID_ID" ] && continue
    pub -r -t "${BASE}/ssid/${SSID_ID}/state" -m "{\"ssid\":\"$(json_escape "$SSID")\",\"band\":\"${BAND}\",\"ifname\":\"${IFACE}\",\"up\":true,\"clients\":${CLIENTS}}" || exit 1
  done || FAILED=1

  [ "$FAILED" -eq 0 ]
}

publish_slow_state() {
  pub -r -t "${BASE}/slow_state" -m "$SLOW_STATE"
}

do_publish() {
  load_config
  check_requirements
  build_state

  NOW="$(date +%s)"
  LAST_HEARTBEAT="$(cat "$HEARTBEAT_FILE" 2>/dev/null)"
  [ -z "$LAST_HEARTBEAT" ] && LAST_HEARTBEAT=0

  HASH="$(printf '%s\n%s\n' "$STATE" "$SSID_STATE" | sha256sum | awk '{print $1}')"
  OLD_HASH="$(cat "$STATE_HASH_FILE" 2>/dev/null)"
  FAILED=0

  if [ "$HASH" != "$OLD_HASH" ]; then
    if publish_state; then
      echo "$HASH" > "$STATE_HASH_FILE"
    else
      FAILED=1
      logger -t openwrt_mqtt 'MQTT fast-state publish failed; will retry'
    fi
  fi

  if [ "$LAST_HEARTBEAT" = "0" ] || [ $((NOW - LAST_HEARTBEAT)) -ge "$HEARTBEAT_SECONDS" ]; then
    build_slow_state
    if publish_slow_state; then
      echo "$NOW" > "$HEARTBEAT_FILE"
    else
      FAILED=1
      logger -t openwrt_mqtt 'MQTT slow-state publish failed; will retry'
    fi
  fi

  [ "$FAILED" -eq 0 ]
}

# A single long-lived mosquitto_pub connection sends retained 'online' to the
# existing device-wide availability topic on every fast poll. That same MQTT
# connection registers retained 'offline' as its Last Will, so HA marks EVERY
# existing sensor unavailable when the broker detects an ungraceful loss.
#
# No additional HA sensor, automation, or MQTT broker configuration is needed.
# Other sensor states continue to be sent via short-lived mosquitto_pub calls.
# The producer and persistent connection share a foreground pipeline, so the
# monitoring loop cannot run independently of the availability connection.
do_daemon_session() {
  # Force full telemetry + discovery on each new connection or after broker
  # recovery; cached hashes from a previous MQTT session must not suppress it.
  rm -f "$STATE_HASH_FILE" "$HEARTBEAT_FILE"

  (
    if do_discovery && do_publish; then
      printf 'online\n' || exit 1
    else
      logger -t openwrt_mqtt 'Initial MQTT telemetry failed; reconnecting'
      printf 'offline\n' || true
      exit 1
    fi

    while :; do
      sleep "$POLL_SECONDS"
      if do_publish; then
        printf 'online\n' || exit 1
      else
        logger -t openwrt_mqtt 'MQTT telemetry failed; marking unavailable and reconnecting'
        printf 'offline\n' || true
        exit 1
      fi
    done
  ) | mosquitto_pub \
      -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
      -l -r -q 1 -k 60 \
      -t "${BASE}/availability" \
      --will-topic "${BASE}/availability" \
      --will-payload 'offline' --will-retain --will-qos 1
}

do_offline() {
  load_config
  # Explicit offline on clean service stop; MQTT Wills apply only when the
  # connection drops unexpectedly and therefore aren't sufficient alone.
  pub -r -q 1 -t "${BASE}/availability" -m 'offline'
}

do_daemon() {
  load_config
  check_requirements
  logger -t openwrt_mqtt "Starting persistent MQTT/LWT daemon for ${HOSTNAME}"

  while :; do
    # Retry through startup ordering problems, broker outages, or Wi-Fi loss.
    do_daemon_session
    logger -t openwrt_mqtt 'MQTT session ended; retrying in 5 seconds'
    sleep 5
  done
}

do_install() {
  echo "Installing OpenWrt MQTT Publisher v${VERSION}"
  echo ""

  # Auto-install mosquitto-client-nossl if missing
  if ! command -v mosquitto_pub >/dev/null 2>&1; then
    echo "Installing mosquitto-client-nossl..."
    apk add mosquitto-client-nossl
    echo ""
  fi

  chmod +x "$SCRIPT"
  create_config
  create_service || exit 1

  do_discovery
  do_publish

  /etc/init.d/openwrt_mqtt stop >/dev/null 2>&1
  /etc/init.d/openwrt_mqtt start

  echo ""
  echo "Install complete."
  echo "Service is running as procd daemon."
}

do_status() {
  load_config
  build_state
  build_slow_state

  echo "OpenWrt MQTT Publisher v${VERSION}"
  echo
  echo "Hostname:      $HOSTNAME"
  echo "Device ID:     $DEVICE_ID"
  echo "Base topic:    $BASE"
  echo "MQTT host:     $MQTT_HOST"
  echo "MQTT user:     $MQTT_USER"
  echo "Discovery:     $DISC"
  echo "Slow state:    $HEARTBEAT_SECONDS seconds (uptime/load/temp/memory)"
  echo "Fast poll/LWT: $POLL_SECONDS seconds (clients/WiFi and online heartbeat)"
  echo "MQTT keepalive: 60 seconds (LWT offline at broker)"
  echo
  echo "Detected SSIDs:"
  echo "$SSID_STATE"
  echo
  echo "Fast state:"
  echo "$STATE"
  echo
  echo "Slow state:"
  echo "$SLOW_STATE"
}

case "$1" in
  install)
    do_install
    ;;
  discovery)
    do_discovery
    ;;
  publish)
    do_publish
    ;;
  daemon)
    do_daemon
    ;;
  all|"")
    do_discovery
    do_publish
    ;;
  status)
    do_status
    ;;
  offline)
    do_offline
    ;;
  install-service)
    # Noninteractive upgrade, preserving /etc/config/openwrt_mqtt unchanged.
    create_service || exit 1
    ;;
  version)
    echo "OpenWrt MQTT Publisher v${VERSION}"
    ;;
  *)
    echo "Usage: $0 install|install-service|discovery|publish|daemon|offline|all|status|version"
    exit 1
    ;;
esac