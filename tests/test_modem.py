"""MF833V discovery, authentication, failure and counter fixtures; no router needed."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'openwrt_mqtt.sh'

class ModemTests(unittest.TestCase):
    def run_fixture(self, mode='normal'):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            source = SOURCE.read_text().split('case "$1" in\n  install)')[0]
            source = source.replace('/usr/share/libubox/jshn.sh', d+'/jshn.sh')
            source = source.replace('/tmp/openwrt_mqtt_modem', d+'/modem')
            (root/'jshn.sh').write_text('''
json_init() { : > "$OUT/fields"; }
json_add_string() { printf '%s|%s|%s\\n' s "$1" "$2" >> "$OUT/fields"; }
json_add_int() { printf '%s|%s|%s\\n' i "$1" "$2" >> "$OUT/fields"; }
json_add_null() { printf '%s|%s|\\n' n "$1" >> "$OUT/fields"; }
json_get_var() { value=$(awk -F '|' -v key="$2" '$2==key && $1!="n" {print $3}' "$OUT/fields"); export "$1=$value"; }
json_dump() { python3 "$OUT/helper.py" dump; }
''')
            (root/'helper.py').write_text('''import json, os, pathlib, sys
p=pathlib.Path(os.environ['OUT'])
if sys.argv[1]=='dump':
 out={}
 for line in (p/'fields').read_text().splitlines():
  kind,key,val=line.split('|',2)
  out[key]=None if kind=='n' else int(val) if kind=='i' else val
 print(json.dumps(out))
else:
 args=sys.argv[2:]
 try:
  data=json.loads(pathlib.Path(args[args.index('-i')+1]).read_text()) if '-i' in args else json.load(sys.stdin)
  val=data[args[args.index('-e')+1][2:]]
  if val is not None: print(val)
 except (ValueError,KeyError): sys.exit(1)
''')
            fixture={'loginfo':'ok','network_type':'LTE','signalbar':'5','lte_rsrp':'-83',
                     'wan_active_band':'LTE BAND 3','realtime_rx_bytes':'5100000000',
                     'realtime_tx_bytes':'31920031','monthly_rx_bytes':'310444732',
                     'monthly_tx_bytes':'35851106'}
            if mode=='invalid':
                fixture.update(lte_rsrp='garbage',signalbar='99',monthly_rx_bytes='',
                               realtime_rx_bytes='not-a-number',monthly_tx_bytes='9'*25)
            (root/'fixture').write_text(json.dumps(fixture))
            harness=r'''
export OUT
MODEM_ENABLED=1
MODEM_HOST=192.168.11.1
BASE=openwrt/test
DEVICE_ID=test
DISC=homeassistant
DEVICE='"device":{"identifiers":["test"]}'
CONFIG=openwrt_mqtt
discovery_pub() { printf '%s\n' "$5" >> "$OUT/discovery"; }
pub() { printf '%s\n' "$*" >> "$OUT/published"; }
jsonfilter() { python3 "$OUT/helper.py" filter "$@"; }
uci() { printf '%s' c2VjcmV0; }
curl() {
 printf 'request\n' >> "$OUT/requests"
 case "$*" in
 *goform_set_cmd_process*)
   secret=$(cat)
   [ "$secret" = c2VjcmV0 ] || return 1
   printf 'login\n' >> "$OUT/logins"
   if [ "$MODE" = badlogin ]; then printf '{"result":"1"}'; else touch "$OUT/authenticated"; printf '{"result":"0"}'; fi ;;
 *)
   [ "$MODE" = unplugged ] && return 7
   if [ -f "$OUT/authenticated" ]; then cat "$OUT/fixture" > "$MODEM_DIR/response";
   else printf '{"loginfo":"timeout","network_type":"LTE"}' > "$MODEM_DIR/response"; fi ;;
 esac
}
modem_discovery
publish_modem || exit 10
publish_modem || exit 11
if [ "$MODE" = normal ]; then
 rm "$OUT/authenticated" "$OUT/modem/login_attempt"
 publish_modem || exit 12
fi
MODEM_ENABLED=0
modem_discovery
publish_modem
'''
            env=dict(os.environ,OUT=d,MODE=mode)
            r=subprocess.run(['sh'],input=source+'\nMODE='+mode+'\nOUT='+d+'\n'+harness,
                             env=env,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            read=lambda name: (root/name).read_text() if (root/name).exists() else ''
            return {name:read(name) for name in ('discovery','published','requests','logins','fields')}

    def test_discovery_and_session_renewal(self):
        result=self.run_fixture()
        payloads=[json.loads(x) for x in result['discovery'].splitlines()]
        self.assertEqual(len(payloads),10)
        self.assertEqual(len({p['unique_id'] for p in payloads}),10)
        self.assertTrue(all(len(p['availability'])==2 for p in payloads))
        traffic=[p for p in payloads if p.get('device_class')=='data_size']
        self.assertEqual(len(traffic),6)
        self.assertTrue(all(p['unit_of_measurement']=='GB' for p in traffic))
        self.assertTrue(all('suggested_unit_of_measurement' not in p for p in payloads))
        self.assertEqual(result['logins'].count('login'),2)
        states=[json.loads(line.split(' -m ',1)[1]) for line in result['published'].splitlines() if '/modem/state -m ' in line]
        self.assertEqual(len(states),1)  # independent change detection
        self.assertEqual(states[0]['band'],'B3')
        self.assertEqual(states[0]['lte_rsrp'],-83)
        self.assertEqual(states[0]['session_total'],'5131920031')  # >32 bit
        self.assertEqual(states[0]['monthly_total'],'346295838')
        self.assertIn('/modem/availability -m online',result['published'])
        self.assertNotIn('c2VjcmV0',result['published'])

    def test_failed_login_backoff(self):
        result=self.run_fixture('badlogin')
        self.assertEqual(result['logins'].count('login'),1)
        self.assertNotIn('/modem/state',result['published'])
        self.assertIn('/modem/availability -m offline',result['published'])

    def test_unplugged_does_not_attempt_login(self):
        result=self.run_fixture('unplugged')
        self.assertEqual(result['logins'],'')
        self.assertIn('/modem/availability -m offline',result['published'])

    def test_invalid_values_are_null_not_zero(self):
        result=self.run_fixture('invalid')
        state=json.loads(next(x.split(' -m ',1)[1] for x in result['published'].splitlines() if '/modem/state -m ' in x))
        for key in ('lte_rsrp','signalbar','monthly_download','monthly_upload','monthly_total','session_total'):
            self.assertIsNone(state[key],key)

if __name__=='__main__': unittest.main()
