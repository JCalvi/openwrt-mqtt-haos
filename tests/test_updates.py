"""Updater integrity, atomic replacement, MQTT discovery and local USB detection."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'openwrt_mqtt.sh'
BODY = SOURCE.read_text().split('case "$1" in\n  install)')[0]

class Updates(unittest.TestCase):
    def run_shell(self, harness, files=None):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for name, data in (files or {}).items():
                (root/name).write_text(data)
            (root/'installed').write_text('#!/bin/sh\nVERSION="1.4.1"\n')
            (root/'filter.py').write_text('''import json,sys
args=sys.argv
try: print(json.load(open(args[args.index('-i')+1]))[args[args.index('-e')+1][2:]])
except Exception: sys.exit(1)
''')
            script=BODY+r'''
UPDATE_DIR="$OUT/update"
SCRIPT="$OUT/installed"
BASE=openwrt/test
DEVICE_ID=test
DISC=homeassistant
DEVICE='"device":{"identifiers":["test"]}'
pub() {
 destination=state
 while [ "$#" -gt 0 ]; do
  if [ "$1" = -t ]; then shift; case "$1" in */update/status) destination=status ;; esac; fi
  if [ "$1" = -m ]; then shift; printf '%s\n' "$1" >> "$OUT/$destination"; return; fi
  shift
 done
}
discovery_pub() { pub "$@"; }
jsonfilter() { python3 "$OUT/filter.py" "$@"; }
is_our_daemon_pid() { return 1; }
update_download() {
 case "$1" in
 */release.json) cp "$OUT/manifest" "$2" ;;
 *) cp "$OUT/candidate" "$2" ;;
 esac
}
'''+harness
            result=subprocess.run(['sh'],input=script,text=True,capture_output=True,env=dict(os.environ,OUT=d))
            contents={str(f.relative_to(root)):f.read_text() for f in root.rglob('*') if f.is_file()}
            return result,contents

    def install(self, mode='valid', version='1.5.0'):
        candidate=f'#!/bin/sh\nVERSION="{version}"\n'
        if mode=='syntax': candidate+='if then\n'
        manifest={'version':version,'commit':'a'*40,'sha256':hashlib.sha256(candidate.encode()).hexdigest()}
        if mode=='hash': manifest['sha256']='0'*64
        if mode=='version': candidate=candidate.replace(version,'9.0.0');manifest['sha256']=hashlib.sha256(candidate.encode()).hexdigest()
        if mode=='manifest': manifest['commit']='../../evil'
        return self.run_shell('update_operation install\n',{'candidate':candidate,'manifest':json.dumps(manifest)})

    def test_valid_install_keeps_backup_and_replaces(self):
        r,f=self.install()
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('1.5.0',f['installed'])
        self.assertIn('1.4.1',f['installed.bak'])
        self.assertFalse(any('lock' in p or '.new.' in p or '/work.' in p for p in f))
        states=[json.loads(s) for s in f['state'].splitlines()]
        self.assertTrue(states[0]['in_progress'])
        self.assertEqual(f['status'].splitlines()[-1],'Installed; restarting publisher')

    def test_failed_validation_never_replaces(self):
        for mode in ('hash','syntax','version','manifest'):
            with self.subTest(mode=mode):
                r,f=self.install(mode)
                self.assertNotEqual(r.returncode,0)
                self.assertIn('1.4.1',f['installed'])
                self.assertNotIn('installed.bak',f)
                self.assertFalse(json.loads(f['state'].splitlines()[-1])['in_progress'])

    def test_equal_or_older_never_installs(self):
        for version in ('1.4.1','1.3.99','0.99.0'):
            r,f=self.install(version=version)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('installed.bak',f)
            self.assertIn('1.4.1',f['installed'])

    def test_check_only_never_installs(self):
        manifest={'version':'1.5.0','commit':'a'*40,'sha256':'b'*64}
        r,f=self.run_shell('update_operation check\n',{'manifest':json.dumps(manifest)})
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('installed.bak',f)
        self.assertEqual(json.loads(f['state'])['latest_version'],'1.5.0')

    def test_download_failure_clears_progress(self):
        r,f=self.run_shell('update_download() { return 7; }; update_operation install\n')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(f['status'].strip(),'Check failed')
        self.assertNotIn('installed.bak',f)

    def test_discovery_is_router_scoped_and_manual(self):
        r,f=self.run_shell('update_discovery\n')
        self.assertEqual(r.returncode,0,r.stderr)
        config=json.loads(f['state'].splitlines()[0])
        self.assertEqual(config['command_topic'],'openwrt/test/update/install')
        self.assertFalse(config['retain'])
        self.assertEqual(config['payload_install'],'INSTALL')

    def test_idle_poll_skips_json_and_network(self):
        r,f=self.run_shell(r'''
update_dir
printf '%s\n' "$VERSION" > "$UPDATE_DIR/published_version"
date +%s > "$UPDATE_DIR/last_check"
jsonfilter() { echo unexpected-json >> "$OUT/unexpected"; return 1; }
update_download() { echo unexpected-network >> "$OUT/unexpected"; return 1; }
publish_update
:
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('unexpected',f)
        self.assertNotIn('state',f)

    def test_listener_ignores_other_commands(self):
        r,f=self.run_shell(r'''
load_config() { :; }
mosquitto_sub() {
 printf '%s\n' "$*" >> "$OUT/subargs"
 if [ -f "$OUT/subscribed" ]; then printf 'INSTALL\n'; else touch "$OUT/subscribed"; printf 'https://evil.invalid/script\n'; fi
}
sleep() { :; }
update_operation() { echo called >> "$OUT/installs"; }
printf '#!/bin/sh\necho refreshed > "$OUT/refreshed"\n' > "$SCRIPT"
chmod 700 "$SCRIPT"
update_listener
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(f['installs'].splitlines(),['called'])
        self.assertIn('-R -C 1',f['subargs'])
        self.assertEqual(f['refreshed'].strip(),'refreshed')

    def test_update_payload_has_only_ha_schema_fields(self):
        r,f=self.run_shell("UPDATE_VERSION=\"1.5.0\"; update_state 'Checked' false\n")
        self.assertEqual(r.returncode,0,r.stderr)
        payload=json.loads(f['state'])
        # HA's MQTT_JSON_UPDATE_SCHEMA rejects unknown keys, including status.
        allowed={'installed_version','latest_version','title','release_summary',
                 'release_url','entity_picture','in_progress','update_percentage'}
        self.assertLessEqual(set(payload),allowed)
        self.assertEqual(payload['installed_version'],'1.4.1')
        self.assertEqual(payload['latest_version'],'1.5.0')
        self.assertIs(payload['in_progress'],False)
        self.assertEqual(f['status'].strip(),'Checked')
        r,f=self.run_shell('update_discovery\n')
        configs=[json.loads(line) for line in f['state'].splitlines()]
        self.assertEqual(configs[1]['state_topic'],'openwrt/test/update/status')
        self.assertNotIn('value_template',configs[1])

    def test_usb_detection(self):
        for route,path,expected in [
            ('192.168.11.1 dev usb0 src 192.168.11.2','/sys/devices/platform/usb1/1-1/1-1:1.0',0),
            ('192.168.11.1 via 192.168.1.11 dev br-lan','/sys/devices/platform/usb1/1-1',1),
            ('192.168.11.1 dev eth1','/sys/devices/platform/ethernet',1),
            ('','',1),
        ]:
            harness='''
MODEM_HOST=192.168.11.1
ip() { printf '%s\\n' "$ROUTE"; }
readlink() { printf '%s\\n' "$DEVICE_PATH"; }
'''+f"ROUTE='{route}'\nDEVICE_PATH='{path}'\nmodem_local_usb\n"
            r,_=self.run_shell(harness)
            self.assertEqual(r.returncode,expected,r.stderr)

    def test_explicit_disable_and_no_credentials(self):
        for mode,credential,expected in [('0','secret',1),('auto','',1),('auto','secret',0),('1','secret',0)]:
            r,_=self.run_shell(f"MODEM_ENABLED={mode}\nuci() {{ printf '%s' '{credential}'; }}\nmodem_configured\n")
            self.assertEqual(r.returncode,expected,r.stderr)

if __name__=='__main__': unittest.main()
