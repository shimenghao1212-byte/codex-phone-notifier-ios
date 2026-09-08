#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Shared/SpeechText.swift tests/SpeechTextRegression.swift -o build/speech-text-regression
build/speech-text-regression
swiftc CodexPhoneNotifier/BluetoothRecovery.swift tests/BluetoothRecoveryRegression.swift -o build/bluetooth-recovery-regression
build/bluetooth-recovery-regression
swiftc CodexPhoneNotifier/AccessoryAuthorization.swift CodexPhoneNotifier/ControlCommandGate.swift tests/AccessoryAuthorizationRegression.swift -o build/accessory-authorization-regression
build/accessory-authorization-regression
swiftc CodexPhoneNotifier/EventFrame.swift tests/EventFrameRegression.swift -o build/event-frame-regression
build/event-frame-regression
swiftc CodexPhoneNotifier/EventFrame.swift CodexPhoneNotifier/ReportWire.swift tests/ReportRegression.swift -o build/report-regression
build/report-regression
swiftc CodexPhoneNotifier/ControlCommandGate.swift tests/ControlCommandRegression.swift -o build/control-command-regression
build/control-command-regression
swiftc Shared/CodexModeStore.swift tests/ModeStoreRegression.swift -o build/mode-store-regression
build/mode-store-regression
plutil -lint Shared/CodexControls.entitlements CodexControls/Info.plist CodexPhoneNotifier/Info.plist CodexPhoneNotifier.xcodeproj/project.pbxproj
xcodebuild -project CodexPhoneNotifier.xcodeproj -scheme CodexPhoneNotifier \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData-voice-report-v1.5 \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build > build/xcodebuild.log 2>&1
python3 scripts/verify-control-metadata.py build/DerivedData-voice-report-v1.5/Build/Products/Debug-iphonesimulator/CodexPhoneNotifier.app
printf '%s\n' 'PASS: simulator compilation; BLE and lock-screen behavior still need a real iPhone.'
