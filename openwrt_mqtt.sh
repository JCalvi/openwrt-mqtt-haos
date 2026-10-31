#!/bin/sh
#
# OpenWrt WiFi MQTT Publisher for Home Assistant
# Version: 1.2.9
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

VERSION="1.2.9"
CONFIG="openwrt_mqtt"
SCRIPT="/root/openwrt_mqtt.sh"
SERVICE="/etc/init.d/openwrt_mqtt"

STATE_HASH_FILE="/tmp/openwrt_mqtt_state.hash"
SSID_HASH_DIR="/tmp/openwrt_mqtt_ssid_hashes"
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

  command -v uci >/dev/null 2>&1 || {
    echo "Missing uci."
    exit 1
  }
}

pub() {
  mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" "$@"
}


# Match only this add-on's long-running script processes, not unrelated shells.
# Inspect /proc arguments without printing them (MQTT passwords may appear in
# mosquitto_pub command lines).
is_our_daemon_pid() {
  [ -r "/proc/$1/cmdline" ] || return 1
  CMD_ARGS="$(tr '\000' '\n' < "/proc/$1/cmdline")"
  CMD1="$(printf '%s\n' "$CMD_ARGS" | sed -n '1p')"
  CMD2="$(printf '%s\n' "$CMD_ARGS" | sed -n '2p')"
  CMD3="$(printf '%s\n' "$CMD_ARGS" | sed -n '3p')"
  if [ "$CMD1" = "$SCRIPT" ] && [ "$CMD2" = "daemon" ]; then
    return 0
  fi
  case "$CMD1" in
    sh|ash|*/sh|*/ash)
      [ "$CMD2" = "$SCRIPT" ] && [ "$CMD3" = "daemon" ]
      return $?
      ;;
  esac
  return 1
}

# Also find any old persistent availability mosquitto_pub clients orphaned by
# a previous shell pipeline. Do not touch other MQTT publishers.
is_our_availability_pid() {
  [ -r "/proc/$1/cmdline" ] || return 1
  CMD_ARGS="$(tr '\000' '\n' < "/proc/$1/cmdline")"
  CMD1="$(printf '%s\n' "$CMD_ARGS" | sed -n '1p')"
  case "$CMD1" in
    mosquitto_pub|*/mosquitto_pub) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$CMD_ARGS" | awk -v topic="${BASE}/availability" '
    $0 == "-l" { line_mode = 1 }
    prev == "-t" && $0 == topic { target = 1 }
    prev == "--will-topic" && $0 == topic { will = 1 }
    { prev = $0 }
    END { exit !(line_mode && target && will) }
  '
}

is_our_legacy_pid() {
  is_our_daemon_pid "$1" || is_our_availability_pid "$1"
}

# This runs before a new procd instance starts and after the old instance
# stops. Sweep only matching daemon/availability processes. A TERM grace
# period is followed by a verified KILL for processes that ignored TERM.
# In particular, this removes orphans left by v1.2.4/v1.2.5.
cleanup_orphans() {
  load_config
  TARGETS=""
  for PROC in /proc/[0-9]*; do
    [ -d "$PROC" ] || continue
    PID="${PROC##*/}"
    [ "$PID" = "$" ] && continue
    if is_our_legacy_pid "$PID"; then
      TARGETS="$TARGETS $PID"
    fi
  done
  [ -n "$TARGETS" ] || return 0

  for PID in $TARGETS; do
    kill -TERM "$PID" 2>/dev/null || true
  done
  sleep 2
  for PID in $TARGETS; do
    if is_our_legacy_pid "$PID"; then
      kill -KILL "$PID" 2>/dev/null || true
    fi
  done
  logger -t openwrt_mqtt "Cleaned up leftover MQTT daemon/availability processes"
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
  command -v iw >/dev/null 2>&1 || return 0
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

# rc.local is a boot-time fallback if an upgrade has dropped the service's
# enabled flag. Leave unrelated rc.local commands untouched. Existing starts
# are moved before the first normal 'exit 0' and consolidated to one line.
ensure_rc_local_start() {
  RCLOCAL="/etc/rc.local"
  RCLOCAL_START="/etc/init.d/openwrt_mqtt start"

  if [ ! -e "$RCLOCAL" ]; then
    printf '#!/bin/sh\n\nexit 0\n' > "$RCLOCAL" || return 1
  fi
  if [ ! -f "$RCLOCAL" ]; then
    echo "Cannot update $RCLOCAL: not a regular file" >&2
    return 1
  fi

  RCLOCAL_TMP="$(mktemp /etc/rc.local.mqtt.XXXXXX)" || return 1
  if ! awk '
    # Remove a standalone start command wherever it appeared, including
    # any copy stranded after exit 0.
    /^[[:space:]]*\/etc\/init[.]d\/openwrt_mqtt[[:space:]]+start([[:space:]]*(#.*)?)?$/ { next }
    # Insert the canonical command before the first normal exit 0.
    /^[[:space:]]*exit[[:space:]]+0([[:space:]]*(#.*)?)?$/ && !inserted {
      print "/etc/init.d/openwrt_mqtt start"
      inserted = 1
    }
    { print }
    END {
      if (!inserted) print "/etc/init.d/openwrt_mqtt start"
    }
  ' "$RCLOCAL" > "$RCLOCAL_TMP"; then
    rm -f "$RCLOCAL_TMP"
    echo "Failed to prepare $RCLOCAL" >&2
    return 1
  fi

  if ! cmp -s "$RCLOCAL_TMP" "$RCLOCAL"; then
    # Write to the existing file so its ownership, mode and any symlink
    # target are not replaced. Keep the original if generation fails.
    if ! cat "$RCLOCAL_TMP" > "$RCLOCAL"; then
      rm -f "$RCLOCAL_TMP"
      echo "Failed to update $RCLOCAL" >&2
      return 1
    fi
  fi
  rm -f "$RCLOCAL_TMP"
  chmod +x "$RCLOCAL" || return 1
  echo "Verified boot fallback in $RCLOCAL: $RCLOCAL_START"
}

create_service() {
  cat > "$SERVICE" <<'SVC'
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

start_service() {
        # OpenWrt procd manages the main PID but older pipeline children
        # can survive. On a fresh start, remove legacy orphans before
        # opening the replacement MQTT availability connection.
        if [ -z "$IPKG_INSTROOT" ] && ! procd_running openwrt_mqtt; then
                /root/openwrt_mqtt.sh cleanup-orphans
        fi
        procd_open_instance
        procd_set_param command /root/openwrt_mqtt.sh daemon
        procd_set_param respawn 3600 5 0
        procd_set_param term_timeout 10
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}

service_stopped() {
        # Called after procd stops the main instance. Remove any
        # remaining pipeline/availability children, then publish offline.
        [ -n "$IPKG_INSTROOT" ] && return 0
        /root/openwrt_mqtt.sh cleanup-orphans
        /root/openwrt_mqtt.sh offline >/dev/null 2>&1 || true
}
SVC

  chmod +x "$SERVICE" || return 1
  if ! "$SERVICE" enable >/dev/null 2>&1; then
    echo "Failed to enable service: $SERVICE" >&2
    return 1
  fi
  ensure_sysupgrade_config || return 1
  ensure_rc_local_start || return 1
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

  mwan_discovery
  [ "$DISCOVERY_FAILED" -eq 0 ]
}

# Read the native nftables mwan3 RPC used by LuCI, including IPv6 policies.
mwan_sections() {
  uci -q show mwan3 | sed -n "s/^mwan3[.]\([a-zA-Z0-9_]*\)=$1$/\1/p"
}

mwan_sensor() {
  MW_UID="${DEVICE_ID}_mwan_$1"
  discovery_pub -r -t "${DISC}/${5:-sensor}/${MW_UID}/config" \
    -m "{\"name\":\"$(json_escape "$2")\",\"unique_id\":\"${MW_UID}\",\"state_topic\":\"${BASE}/mwan3/state\",\"availability\":[{\"topic\":\"${BASE}/availability\"},{\"topic\":\"${BASE}/mwan3/availability\"}],\"availability_mode\":\"all\",\"value_template\":\"$(json_escape "$3")\",$4${DEVICE}}"
}

mwan_discovery() {
  [ -f /etc/config/mwan3 ] || return 0
  for MI in $(mwan_sections interface); do
    mwan_sensor "${MI}_status" "MWAN ${MI} Status" "{{ value_json.interfaces.get('$MI', {}).get('status', 'unknown') }}" ''
    mwan_sensor "${MI}_connected" "MWAN ${MI} Connected" "{{ 'true' if value_json.interfaces.get('$MI', {}).get('status') == 'online' else 'false' }}" '"device_class":"connectivity","payload_on":"true","payload_off":"false",' binary_sensor
    mwan_sensor "${MI}_online" "MWAN ${MI} Online Duration" "{% set s = value_json.interfaces.get('$MI', {}).get('online', 0) | int(0) %}{% if s < 3600 %}{{ s // 60 }}m {{ s % 60 }}s{% elif s < 86400 %}{{ s // 3600 }}h {{ s % 3600 // 60 }}m{% else %}{{ s // 86400 }}d {{ s % 86400 // 3600 }}h{% endif %}" '"icon":"mdi:timer-outline",'
  done
  for MP in $(mwan_sections policy); do
    for MF in ipv4 ipv6; do
      MW_MEMBERS=''
      for MM in $(uci -q get "mwan3.$MP.use_member"); do
        MI="$(uci -q get "mwan3.$MM.interface")"
        [ "$(uci -q get "mwan3.$MI.family")" = "$MF" ] || continue
        case "$MI" in ''|*[!a-zA-Z0-9_]*) continue ;; esac
        case " $MW_MEMBERS " in *" $MI "*) continue ;; esac
        MW_MEMBERS="$MW_MEMBERS $MI"
        mwan_sensor "${MP}_${MF}_${MI}_percent" "MWAN ${MP} ${MI} Allocation" "{% set ns = namespace(p=0) %}{% for m in value_json.policies.get('$MF', {}).get('$MP', []) %}{% if m.interface == '$MI' %}{% set ns.p = m.percent %}{% endif %}{% endfor %}{{ ns.p }}" '"unit_of_measurement":"%",'
      done
      [ -n "$MW_MEMBERS" ] || continue
      mwan_sensor "${MP}_${MF}_active" "MWAN ${MP} ${MF} Active Connection" "{% set ns = namespace(active=[]) %}{% for m in value_json.policies.get('$MF', {}).get('$MP', []) %}{% if m.percent | float(0) > 0 %}{% set ns.active = ns.active + [m.interface] %}{% endif %}{% endfor %}{{ ns.active | join(', ') if ns.active else 'none' }}" ''
    done
  done
}

publish_mwan() {
  [ -f /etc/config/mwan3 ] || return 0
  MW_STATE="$(ubus -t 5 call mwan3 status 2>/dev/null)"
  if [ -z "$MW_STATE" ] || ! printf '%s' "$MW_STATE" | jsonfilter -e '@.interfaces' >/dev/null 2>&1; then
    # Invalidate stale healthy readings if mwan3 is stopped or missing.
    pub -r -t "${BASE}/mwan3/availability" -m offline
    return $?
  fi
  MW_HASH="$(printf '%s' "$MW_STATE" | sha256sum | awk '{print $1}')"
  if [ "$MW_HASH" != "$(cat /tmp/openwrt_mqtt_mwan.hash 2>/dev/null)" ]; then
    pub -r -t "${BASE}/mwan3/state" -m "$MW_STATE" || return 1
    printf '%s\n' "$MW_HASH" > /tmp/openwrt_mqtt_mwan.hash || return 1
  fi
  pub -r -t "${BASE}/mwan3/availability" -m online
}

build_state() {
  TOTAL_CLIENTS="$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | while read -r IFACE; do iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station'; done | awk '{s+=$1} END {print s+0}')"

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

# Maintain independent hashes for each MQTT state topic. A changed client
# count on one SSID should not republish every other SSID and the main state.
# Hashes are written only after successful publication so failures are retried.
publish_state() {
  FAILED=0

  MAIN_HASH="$(printf '%s' "$STATE" | sha256sum | awk '{print $1}')"
  if [ "$MAIN_HASH" != "$(cat "$STATE_HASH_FILE" 2>/dev/null)" ]; then
    if pub -r -t "${BASE}/state" -m "$STATE"; then
      printf '%s\n' "$MAIN_HASH" > "$STATE_HASH_FILE" || FAILED=1
    else
      FAILED=1
    fi
  fi

  mkdir -p "$SSID_HASH_DIR" || return 1
  if ! printf '%s\n' "$SSID_STATE" | while IFS='|' read -r SSID_ID SSID BAND IFACE CLIENTS; do
    [ -z "$SSID_ID" ] && continue

    SSID_PAYLOAD="{\"ssid\":\"$(json_escape "$SSID")\",\"band\":\"${BAND}\",\"ifname\":\"${IFACE}\",\"up\":true,\"clients\":${CLIENTS}}"
    SSID_HASH="$(printf '%s' "$SSID_PAYLOAD" | sha256sum | awk '{print $1}')"
    SSID_HASH_FILE="${SSID_HASH_DIR}/${SSID_ID}.hash"

    if [ "$SSID_HASH" != "$(cat "$SSID_HASH_FILE" 2>/dev/null)" ]; then
      pub -r -t "${BASE}/ssid/${SSID_ID}/state" -m "$SSID_PAYLOAD" || exit 1
      printf '%s\n' "$SSID_HASH" > "$SSID_HASH_FILE" || exit 1
    fi
  done; then
    FAILED=1
  fi

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

  FAILED=0

  if ! publish_mwan; then
    FAILED=1
  fi

  if ! publish_state; then
    FAILED=1
    logger -t openwrt_mqtt 'MQTT fast-state publish failed; will retry'
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

# Keep a single long-lived availability/LWT publisher and a background
# producer linked by a FIFO. Both child PIDs are tracked so SIGTERM from
# procd can terminate and reap them instead of leaving pipeline orphans.
# Changed telemetry still publishes to the existing retained MQTT topics.
session_producer() {
  PRODUCER_SLEEP_PID=""
  trap 'if [ -n "$PRODUCER_SLEEP_PID" ]; then kill "$PRODUCER_SLEEP_PID" 2>/dev/null || true; fi; exit 0' TERM INT HUP

  if do_discovery && do_publish; then
    printf 'online\n' || return 1
  else
    logger -t openwrt_mqtt 'Initial MQTT telemetry failed; reconnecting'
    printf 'offline\n' || true
    return 1
  fi

  while :; do
    sleep "$POLL_SECONDS" &
    PRODUCER_SLEEP_PID=$!
    wait "$PRODUCER_SLEEP_PID" || return 1
    PRODUCER_SLEEP_PID=""

    if do_publish; then
      printf 'online\n' || return 1
    else
      logger -t openwrt_mqtt 'MQTT telemetry failed; marking unavailable and reconnecting'
      printf 'offline\n' || true
      return 1
    fi
  done
}

stop_session() {
  for CHILD in "$PRODUCER_PID" "$MQTT_PID" "$RETRY_SLEEP_PID"; do
    [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null || true
  done
  for CHILD in "$PRODUCER_PID" "$MQTT_PID" "$RETRY_SLEEP_PID"; do
    [ -n "$CHILD" ] && wait "$CHILD" 2>/dev/null || true
  done
  [ -n "$SESSION_FIFO" ] && rm -f "$SESSION_FIFO"
  PRODUCER_PID=""
  MQTT_PID=""
  RETRY_SLEEP_PID=""
  SESSION_FIFO=""
}

terminate_daemon() {
  trap - TERM INT HUP
  stop_session
  exit 0
}

do_daemon_session() {
  # Force a full republish on each new MQTT connection or broker recovery.
  rm -f "$STATE_HASH_FILE" "$HEARTBEAT_FILE" /tmp/openwrt_mqtt_mwan.hash
  rm -rf "$SSID_HASH_DIR"

  SESSION_FIFO="/tmp/openwrt_mqtt_$$.fifo"
  rm -f "$SESSION_FIFO"
  umask 077
  if ! mkfifo "$SESSION_FIFO"; then
    logger -t openwrt_mqtt 'Failed to create MQTT publisher FIFO'
    SESSION_FIFO=""
    return 1
  fi

  ( session_producer ) > "$SESSION_FIFO" &
  PRODUCER_PID=$!
  mosquitto_pub \
      -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
      -l -r -q 1 -k 60 \
      -t "${BASE}/availability" \
      --will-topic "${BASE}/availability" \
      --will-payload 'offline' --will-retain --will-qos 1 \
      < "$SESSION_FIFO" &
  MQTT_PID=$!

  wait "$MQTT_PID"
  SESSION_RESULT=$?
  stop_session
  return "$SESSION_RESULT"
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
  PRODUCER_PID=""
  MQTT_PID=""
  RETRY_SLEEP_PID=""
  SESSION_FIFO=""
  trap 'terminate_daemon' TERM INT HUP
  logger -t openwrt_mqtt "Starting persistent MQTT/LWT daemon for ${HOSTNAME}"

  while :; do
    # Retry through startup ordering problems, broker outages, or Wi-Fi loss.
    do_daemon_session
    logger -t openwrt_mqtt 'MQTT session ended; retrying in 5 seconds'
    sleep 5 &
    RETRY_SLEEP_PID=$!
    wait "$RETRY_SLEEP_PID" || true
    RETRY_SLEEP_PID=""
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
  cleanup-orphans)
    cleanup_orphans
    ;;
  install-service)
    # Noninteractive upgrade, preserving /etc/config/openwrt_mqtt unchanged.
    create_service || exit 1
    ;;
  version)
    echo "OpenWrt MQTT Publisher v${VERSION}"
    ;;
  *)
    echo "Usage: $0 install|install-service|discovery|publish|daemon|offline|cleanup-orphans|all|status|version"
    exit 1
    ;;
esac
