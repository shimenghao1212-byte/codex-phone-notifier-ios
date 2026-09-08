#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ios_root="$PWD"
out="$ios_root/build/control-ui"
mkdir -p "$out"
app="$ios_root/build/DerivedData-voice-report-v1.5/Build/Products/Debug-iphonesimulator/CodexPhoneNotifier.app"
# Keep Xcode's normal simulator entitlements; do not replace them with a partial set.
codesign -d --entitlements :- "$app" > "$out/host-entitlements.plist" 2> "$out/codesign.log"
codesign -d --entitlements :- "$app/PlugIns/CodexControls.appex" > "$out/control-entitlements.plist" 2>> "$out/codesign.log"
xcrun simctl list runtimes --json > "$out/runtimes.json"
runtime="$(python3 - "$out/runtimes.json" <<'PY'
import json, sys
values = json.load(open(sys.argv[1]))['runtimes']
runtime = next(r for r in values if r.get('isAvailable') and r['name'] == 'iOS 18.5')
print(runtime['identifier'])
PY
)"
shared_sim="$ios_root/build/screenshots/simulator-id.txt"
if [ -f "$shared_sim" ]; then
  sim="$(cat "$shared_sim")"
  # Only a simulator created inside this same disposable CI job is reused.
  xcrun simctl list devices --json > "$out/devices.json"
  python3 - "$out/devices.json" "$sim" "$runtime" <<'PY'
import json, sys
values = json.load(open(sys.argv[1]))['devices'][sys.argv[3]]
assert any(v['udid'] == sys.argv[2] and v['name'] == 'Codex-Visual-QA' and v['state'] == 'Booted' for v in values)
PY
  # Design captures repeatedly launch/terminate the fixture host. On a busy
  # runner, chronod can retain its suspended descriptor extension and watchdog
  # live-session startup before it resumes. Start a clean system session once,
  # retaining this job's exact installed app and shared container. No test retry
  # or state assertion is skipped, and no system daemon is killed selectively.
  xcrun simctl shutdown "$sim"
  xcrun simctl boot "$sim"
  xcrun simctl bootstatus "$sim" -b
else
  sim="$(xcrun simctl create Codex-Control-UI com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$runtime")"
  xcrun simctl boot "$sim"
  xcrun simctl bootstatus "$sim" -b
fi
cleanup() {
  xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
  xcrun simctl delete "$sim" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl ui "$sim" appearance dark
# The shared simulator already has this exact Debug app. Reinstalling its
# extension immediately before gallery lookup can invalidate WidgetKit's index.
if [ ! -f "$shared_sim" ]; then
  xcrun simctl install "$sim" "$app"
fi
xcrun simctl get_app_container "$sim" local.codex.phone.notifier groups > "$out/groups.txt" 2>&1 || true
set +e
xcodebuild -project ui-tests/ControlCenterUITests.xcodeproj -scheme ControlCenterUITests \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/ControlUITestDerived \
  -resultBundlePath "$out/ControlCenter.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 150 \
  -maximum-test-execution-time-allowance 180 CODE_SIGNING_ALLOWED=NO \
  test > "$ios_root/build/control-ui.log" 2>&1
result=$?
xcrun simctl spawn "$sim" log show --last 10m --style compact \
  --predicate '(process == "CodexControls") OR (eventMessage CONTAINS[c] "local.codex.phone") OR (eventMessage CONTAINS[c] "CodexControls")' \
  > "$out/extension-system.log" 2>&1
python3 - "$out" <<'PY'
from pathlib import Path
import shutil, sys
out = Path(sys.argv[1])
reports = Path.home() / 'Library/Logs/DiagnosticReports'
for path in sorted(reports.glob('CodexControls*'), key=lambda p: p.stat().st_mtime)[-4:]:
    if path.is_file():
        shutil.copy2(path, out / path.name)
PY
xcrun xcresulttool export attachments --path "$out/ControlCenter.xcresult" \
  --output-path "$out/attachments" > "$out/export.log" 2>&1
xcrun xcresulttool get test-results summary --path "$out/ControlCenter.xcresult" \
  > "$out/summary.json" 2>> "$out/export.log"
xcrun simctl io "$sim" screenshot "$out/last-screen.png" >/dev/null 2>&1
set -e
python3 - "$out" "$result" <<'PY'
from pathlib import Path
import json, sys
out = Path(sys.argv[1])
registration_observed = 'foreground shortcut metadata registration requested' in (out / 'extension-system.log').read_text(errors='replace')
if int(sys.argv[2]) == 0:
    assert registration_observed, 'Foreground metadata registration lifecycle was not exercised'
(out / 'scope.json').write_text(json.dumps({
    'test_exit_code': int(sys.argv[2]),
    'foreground_metadata_registration_observed': registration_observed,
    'system_ui': 'real iOS 18.5 Control Center, WidgetKit and App Intents',
    'bluetooth': 'simulated; Debug isolated simulator only',
    'physical_device_or_Apple_development_signing_verified': False
}, indent=2))
PY
exit "$result"
