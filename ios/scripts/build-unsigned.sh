#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ios_root="$PWD"
repo_root="$(cd .. && pwd)"
mkdir -p "$ios_root/build" "$repo_root/build"

xcodebuild -project CodexPhoneNotifier.xcodeproj \
  -scheme CodexPhoneNotifier -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$repo_root/build/DerivedData-voice-report-v1.5" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build > "$ios_root/build/device-build.log" 2>&1

app_path="$repo_root/build/DerivedData-voice-report-v1.5/Build/Products/Release-iphoneos/CodexPhoneNotifier.app"
python3 scripts/verify-control-metadata.py "$app_path"
# Ad-hoc signatures carry the requested App Group into the resigning tool.
# They are NOT Apple development signatures and cannot install on an iPhone as-is.
codesign --force --sign - --entitlements Shared/CodexControls.entitlements "$app_path/PlugIns/CodexControls.appex"
codesign --force --sign - --entitlements Shared/CodexControls.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
python3 - "$app_path" <<'PY' 
from pathlib import Path
import plistlib
import sys
import subprocess

app = Path(sys.argv[1])
extensions = list(app.rglob('*.appex'))
assert len(extensions) == 1 and extensions[0].name == 'CodexControls.appex'
with (extensions[0] / 'Info.plist').open('rb') as handle:
    ext_info = plistlib.load(handle)
assert ext_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
assert ext_info['CFBundleIdentifier'] == 'local.codex.phone.notifier.controls'
assert ext_info['CFBundleShortVersionString'] == '1.8.4'
assert str(ext_info['CFBundleVersion']) == '15'
assert (extensions[0] / ext_info['CFBundleExecutable']).is_file()
assert (extensions[0] / 'Metadata.appintents').is_dir(), 'Missing extension Intent metadata'
assert (app / 'Metadata.appintents').is_dir(), 'Missing host Intent metadata'
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert (app / info['CFBundleExecutable']).is_file(), 'Missing App executable'
binary = (app / info['CFBundleExecutable']).read_bytes()
for test_flag in [b'CODEX_CONTROL_UI_TEST', b'codexControlUITest']:
    assert test_flag not in binary, 'Simulator control fixture leaked into Release'
assert info['CFBundleShortVersionString'] == '1.8.4'
assert str(info['CFBundleVersion']) == '15'
assert info['NSAccessorySetupSupports'] == ['Bluetooth']
assert info['NSAccessorySetupKitSupports'] == ['Bluetooth']
assert info['NSAccessorySetupBluetoothServices'] == ['5E2F4D60-A84C-4DB0-89ED-95A76E5AC901']
assert 'NSAccessorySetupSupports' not in ext_info
assert tuple(map(int, info['MinimumOSVersion'].split('.')[:2])) >= (16, 4)
assert info['NSSupportsLiveActivities'] is True  # Allows cleanup of legacy 1.1 sessions.
for bundle in [app, extensions[0]]:
    raw = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
    signed = plistlib.loads(raw)
    assert signed['com.apple.security.application-groups'] == ['group.local.codex.phone.notifier']
print('PASS: App + Controls 1.8.4 (15), both request the same App Group; requires Apple resigning.')
PY

staging_path="$(mktemp -d "$repo_root/build/ipa-stage.XXXXXX")"
mkdir -p "$staging_path/Payload"
ditto "$app_path" "$staging_path/Payload/CodexPhoneNotifier.app"
ditto -c -k --keepParent "$staging_path/Payload" "$repo_root/build/CodexPhoneNotifier-unsigned.ipa"
printf '%s\n' "Unsigned IPA: $repo_root/build/CodexPhoneNotifier-unsigned.ipa"
