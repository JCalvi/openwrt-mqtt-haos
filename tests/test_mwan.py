"""No broker/router required: exercise discovery and RPC failure handling."""
import json, pathlib, subprocess, tempfile, unittest
SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt_mqtt.sh'
class MwanTests(unittest.TestCase):
    def test_discovery_and_publication(self):
        with tempfile.TemporaryDirectory() as d:
            source=SOURCE.read_text().split('case "$1" in\n  install)')[0]
            source=source.replace('[ -f /etc/config/mwan3 ] || return 0', ':')
            source=source.replace('/tmp/openwrt_mqtt_mwan.hash',d+'/hash')
            harness=r'''
BASE=openwrt/test
DEVICE_ID=test
DISC=homeassistant
DEVICE='"device":{"identifiers":["test"]}'
mwan_sections() {
 case "$1" in interface) echo 'wan mobile wan6 mobile6';; policy) echo 'failover failover6';; esac
}
uci() {
 case "$*" in
 *failover.use_member) echo 'wp mb';;
 *failover6.use_member) echo 'w6 m6';;
 *wp.interface) echo wan;; *mb.interface) echo mobile;;
 *w6.interface) echo wan6;; *m6.interface) echo mobile6;;
 *wan.family|*mobile.family) echo ipv4;;
 *wan6.family|*mobile6.family) echo ipv6;;
 esac
}
discovery_pub() { printf '%s\n' "$5" >> "$OUT/discovery"; }
pub() { printf '%s\n' "$*" >> "$OUT/published"; }
ubus() { cat "$OUT/fixture"; }
jsonfilter() { python3 -c 'import sys,json; assert isinstance(json.load(sys.stdin)["interfaces"],dict)'; }
mwan_discovery
publish_mwan
: > "$OUT/fixture"
publish_mwan
'''
            pathlib.Path(d+'/fixture').write_text(json.dumps({'interfaces':{'wan':{'status':'online','online':9120}},'policies':{'ipv4':{'failover':[{'interface':'wan','percent':100},{'interface':'mobile','percent':0}]},'ipv6':{'failover6':[{'interface':'wan6','percent':100}]}}}))
            r=subprocess.run(['sh'],input=source+'\nOUT='+d+'\n'+harness,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            payloads=[json.loads(x) for x in pathlib.Path(d+'/discovery').read_text().splitlines()]
            self.assertEqual(len(payloads),18) # 12 interface, 4 percentages, 2 active
            self.assertEqual(len({p['unique_id'] for p in payloads}),18)
            for p in payloads:
                self.assertEqual(p['availability_mode'],'all')
                self.assertEqual(len(p['availability']),2)
            connected=[p for p in payloads if p.get('device_class') == 'connectivity']
            self.assertEqual(len(connected),4)
            self.assertEqual({p['unique_id'] for p in connected},
                             {f'test_mwan_{i}_connected' for i in ('wan','mobile','wan6','mobile6')})
            for p in connected:
                self.assertEqual(p['payload_on'],'true')
                self.assertEqual(p['payload_off'],'false')
                self.assertIn("== 'online'",p['value_template'])
            published=pathlib.Path(d+'/published').read_text()
            self.assertIn('mwan3/state',published)
            self.assertIn('mwan3/availability -m online',published)
            self.assertIn('mwan3/availability -m offline',published)
if __name__ == '__main__': unittest.main()
