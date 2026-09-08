# Codex Bluetooth notifier for iOS

A native iOS companion for a compatible nearby Bluetooth Low Energy peripheral.
This is an independent personal project, not an official OpenAI application.

Features include a single persistent Control Center toggle, local task alerts,
optional CallKit voice reports, and bounded latest-only report/image handling.
The desktop companion is not included in this native build snapshot.

Version 1.8.4 (15) fixes a launch crash by declaring both AccessorySetupKit
support keys and validating configuration before native session creation.
Accessory authorization and migration precede CoreBluetooth state restoration. One foreground system authorization is required
on upgrade. This is a candidate improvement, not a claim of guaranteed background
delivery. Actual BLE pairing, migration, and locked-device behavior require hardware.

## Build and validation

The manual GitHub Actions workflow uses the standard macos-15 runner, runs native
protocol/state regressions, builds Debug and Release, and exercises the actual
Control Center UI in an isolated simulator. A separate non-fixture cold-launch
test exercises the native session constructor. Hardware BLE is not simulated by
that startup test; actual pairing and restoration still require a real iPhone.
It contains no signing credentials and produces an unsigned IPA that needs the
user's own Apple development signing before installation.

No periodic keepalive, location mode, remote push service, or network speech
service is added. This snapshot contains only native source, synthetic tests,
UI assets, project metadata, and the build workflow. It includes no private Git
history, device records, user conversations, local reports, or desktop configuration.

References: [Apple accessory setup](https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories),
[Bluetooth relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).
