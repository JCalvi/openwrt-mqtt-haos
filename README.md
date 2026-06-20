# openwrt-mqtt-haos

Publishes OpenWrt router stats to Home Assistant via MQTT discovery.

Tested on GL-MT6000 running Alpine-based OpenWrt.

## Sensors

| Sensor | Update frequency |
|--------|------------------|
| Per-SSID client count | Every poll (default 60s) |
| Per-SSID up/down | Every poll (default 60s) |
| Total clients | Every poll (default 60s) |
| WiFi Healthy | Every poll (default 60s) |
| CPU Temperature | Every heartbeat (default 300s) |
| Memory Used | Every heartbeat (default 300s) |
| Load 1m | Every heartbeat (default 300s) |
| Uptime | Every heartbeat (default 300s) |

Uptime displays as:
- `2m 34s` — under 1 hour
- `3h 12m` — under 1 day
- `6d 11h` — 1 day or more

## Requirements

- OpenWrt (Alpine/apk-based, 23.05+)
- `mosquitto-client-nossl` — installed automatically by the script
- `iw` — included in OpenWrt by default
- Home Assistant with MQTT integration and a broker (e.g. Mosquitto)

## Install

```sh
# Download the script
wget -O /root/openwrt_mqtt.sh https://raw.githubusercontent.com/JCalvi/openwrt-mqtt-haos/main/openwrt_mqtt.sh
chmod +x /root/openwrt_mqtt.sh

# Run the installer
/root/openwrt_mqtt.sh install
```

The installer will:
1. Auto-install `mosquitto-client-nossl` if missing
2. Prompt for MQTT configuration (host, user, password, discovery prefix, poll interval, heartbeat)
3. Install and enable a procd service that starts on boot
4. Publish MQTT discovery and initial state

## Configuration

Config is stored in `/etc/config/openwrt_mqtt`:

```
config mqtt
        option host '192.168.1.20'
        option user 'openwrt'
        option password 'yourpassword'
        option discovery_prefix 'homeassistant'
        option poll_interval '60'
        option heartbeat '300'
```

Changes are picked up automatically on the next poll cycle — no restart needed.

## Commands

| Command | Description |
|---------|-------------|
| `install` | Full install: deps, config, service, discovery, publish |
| `discovery` | Re-publish MQTT discovery payloads |
| `publish` | Publish current state once |
| `daemon` | Run as a continuous polling daemon |
| `status` | Show current config and state |
| `version` | Print version |

## Service

```sh
/etc/init.d/openwrt_mqtt start
/etc/init.d/openwrt_mqtt stop
/etc/init.d/openwrt_mqtt restart
```

## MQTT Topics

| Topic | Contents |
|-------|----------|
| `openwrt/{device_id}/availability` | `online` / `offline` |
| `openwrt/{device_id}/state` | clients, healthy |
| `openwrt/{device_id}/slow_state` | uptime, load, temp, memory |
| `openwrt/{device_id}/ssid/{ssid_id}/state` | per-SSID clients and up/down |
