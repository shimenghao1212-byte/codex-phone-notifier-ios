#!/bin/bash
# Uses an isolated simulator. Fixture UI only exists in Debug simulator builds.
set -euo pipefail
cd "$(dirname "$0")/.."
ios_root="$PWD"
app_path="$ios_root/build/DerivedData-voice-report-v1.5/Build/Products/Debug-iphonesimulator/CodexPhoneNotifier.app"
output_path="$ios_root/build/screenshots"
mkdir -p "$output_path"
test -d "$app_path"
test -d "$app_path/PlugIns/CodexControls.appex"

xcrun simctl list runtimes --json > "$output_path/runtimes.json"
xcrun simctl list devicetypes --json > "$output_path/device-types.json"
selection="$(python3 - "$output_path" <<'PY'
from pathlib import Path
import json
import sys

folder = Path(sys.argv[1])
runtimes = [r for r in json.loads((folder / 'runtimes.json').read_text())['runtimes']
            if r.get('isAvailable') and 'iOS' in r['name']]
assert runtimes, 'No installed iOS simulator runtime'
runtime = next(r for r in runtimes if r['name'] == 'iOS 18.5')
types = json.loads((folder / 'device-types.json').read_text())['devicetypes']
preferred = ['iPhone 16 Pro', 'iPhone 15 Pro', 'iPhone 14 Pro']
device = next((t for name in preferred for t in types if t['name'] == name), None)
assert device, 'No supported iPhone simulator device type'
print(runtime['identifier'])
print(device['identifier'])
PY
)"
runtime_id="$(printf '%s\n' "$selection" | sed -n '1p')"
device_type="$(printf '%s\n' "$selection" | sed -n '2p')"
simulator_id="$(xcrun simctl create Codex-Visual-QA "$device_type" "$runtime_id")"
cleanup() {
  if [ "${CODEX_KEEP_SIMULATOR:-0}" = '1' ]; then
    xcrun simctl terminate "$simulator_id" local.codex.phone.notifier >/dev/null 2>&1 || true
    printf '%s\n' "$simulator_id" > "$output_path/simulator-id.txt"
    return
  fi
  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl ui "$simulator_id" appearance dark
xcrun simctl status_bar "$simulator_id" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$simulator_id" "$app_path"

SIMCTL_CHILD_CODEX_DESIGN_PREVIEW=home xcrun simctl launch \
  "$simulator_id" local.codex.phone.notifier >> "$output_path/launch.log" 2>&1
sleep 3
xcrun simctl io "$simulator_id" screenshot "$output_path/home.png"
for screen in report settings; do
  xcrun simctl terminate "$simulator_id" local.codex.phone.notifier
  SIMCTL_CHILD_CODEX_DESIGN_PREVIEW="$screen" xcrun simctl launch "$simulator_id" local.codex.phone.notifier >> "$output_path/launch.log" 2>&1
  sleep 3
  xcrun simctl io "$simulator_id" screenshot "$output_path/$screen.png"
done
python3 - "$output_path" "$runtime_id" "$device_type" <<'PY'
from pathlib import Path
import json
import sys

folder, runtime, device = sys.argv[1:]
out = Path(folder)
data = {
    'runtime': runtime,
    'device_type': device,
    'home.png': 'Actual simulator app render; DEBUG simulator connection fixture.',
    'report.png': 'Latest report sheet with synthetic text and an existing local preview asset.',
    'settings.png': 'Settings sheet including alert mode selection.',
    'version': '1.8.3 (14)',
    'live_activity_creation': False,
    'physical_ble_or_lock_screen_test': False,
}
(out / 'capture-metadata.json').write_text(json.dumps(data, indent=2) + '\n')
(out / 'README.txt').write_text(
    'home.png, report.png, settings.png: actual Debug simulator screens with synthetic fixture data.\n'
    'This version creates no Live Activities and embeds one Controls extension.\n'
    'Review screenshots visually. They do not verify BLE, sound, background delivery, signing, or legacy activity cleanup.\n'
    'Fixture code is excluded from physical-device and Release builds.\n'
)
print('PASS: actual simulator home, report and settings screens captured; visual inspection required.')
PY
