import Foundation

@main
struct AccessoryAuthorizationRegression {
    static func main() {
        let original = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let first = AccessoryAuthorization.Computer(id: original, name: "原电脑")
        let second = AccessoryAuthorization.Computer(id: other, name: "另一台电脑")
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }

        let service = "00000000-0000-4000-8000-000000000003"
        let valid: [String: Any] = ["NSAccessorySetupSupports": ["Bluetooth"],
            "NSAccessorySetupKitSupports": ["Bluetooth"], "NSAccessorySetupBluetoothServices": [service]]
        check(AccessoryAuthorization.supportsBluetooth(info: valid, serviceUUID: service), "Valid packaged declarations")
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            check(!AccessoryAuthorization.supportsBluetooth(info: missing, serviceUUID: service), "Reject missing declaration before native init")
            missing[key] = "Bluetooth"
            check(!AccessoryAuthorization.supportsBluetooth(info: missing, serviceUUID: service), "Reject incorrect plist type")
            missing[key] = [String]()
            check(!AccessoryAuthorization.supportsBluetooth(info: missing, serviceUUID: service), "Reject empty declaration")
        }
        check(!AccessoryAuthorization.supportsBluetooth(info: valid, serviceUUID: original.uuidString), "Reject undeclared service")

        // Cold background launch cannot use a cached preference as OS authorization.
        var state = AccessoryAuthorization()
        check(!state.permits(original), "Wait for OS authorization snapshot")
        check(!state.claimCentral(for: original), "Cannot initialize central during loading")
        check(!state.beginPicker(selected: original), "Cannot show a picker before activation")
        state.refresh([])
        check(!state.permits(original), "A saved peripheral is not an authorization grant")
        check(state.beginPicker(selected: original), "Existing device can migrate once")
        check(state.migrationID == original, "Migrate exactly the saved identity")
        check(!state.beginPicker(selected: other), "Rapid second tap cannot replace a picker")
        state.refresh([first])
        check(!state.permits(original), "accessoryAdded is not migrationComplete")
        check(!state.claimCentral(for: original), "No central while migration is in progress")
        state.migrationCompleted()
        check(state.permits(original), "Explicit migration completion unlocks the approved device")
        check(!state.permits(other), "Another device cannot inherit the grant")
        check(state.claimCentral(for: original), "Create one restoration manager")
        check(!state.claimCentral(for: original), "No duplicate manager")
        state.finishPicker()
        check(state.permits(original), "Dismissal preserves completed migration")

        // Revocation must immediately defeat pending starts and future connects.
        state.refresh([])
        check(!state.permits(original), "Removing OS grant takes effect immediately")
        check(state.beginPicker(selected: original), "Can request a fresh system authorization")
        check(state.migrationID == nil, "Never migrate after a manager existed")
        state.refresh([second])
        state.finishPicker()
        check(!state.permits(original) && state.permits(other), "Only selected OS identity is granted")
        state.invalidate()
        check(state.phase == .failed && !state.permits(other), "Invalid session fails closed")
        check(!state.beginPicker(selected: other), "Invalid session cannot create a picker")
        var replacement = AccessoryAuthorization(centralAlreadyCreated: true)
        replacement.refresh([])
        check(replacement.beginPicker(selected: original), "User can retry after invalid OS session")
        check(replacement.migrationID == nil, "Replacing the session cannot forget an existing central")
        replacement.refresh([first])
        replacement.finishPicker()
        check(!replacement.claimCentral(for: original), "A replacement session cannot duplicate the manager")

        // Cancelling/failing an incomplete migration must not accept a premature added event.
        var canceled = AccessoryAuthorization()
        canceled.refresh([])
        _ = canceled.beginPicker(selected: original)
        canceled.refresh([first])
        canceled.finishPicker()
        check(!canceled.permits(original), "Cancelled incomplete migration is not authorization")
        check(!canceled.claimCentral(for: original), "Cancellation cannot start Bluetooth")
        check(canceled.beginPicker(selected: original), "Cancellation permits explicit retry")
        check(canceled.migrationID == original, "Retry still uses migration before any central")
        canceled.finishPicker()
        check(canceled.beginPicker(selected: nil), "Explicit rediscovery can recover a stale saved identity")
        check(canceled.migrationID == nil, "Rediscovery must not retry the stale migration")
        canceled.refresh([second])
        canceled.finishPicker()
        check(canceled.permits(other) && !canceled.permits(original), "Rediscovery authorizes only the new choice")

        // Previously authorized cold launches need no picker, but still check OS identity.
        var restored = AccessoryAuthorization()
        restored.refresh([first, second])
        check(restored.claimCentral(for: original), "Background restoration creates manager promptly")
        check(!restored.pickerActive, "Background restoration never opens UI")
        check(!restored.permits(nil), "Missing selection cannot attach to an arbitrary device")

        // Authorization completion must not undo a later OFF command.
        var commands = ControlCommandGate()
        let picker = commands.begin()
        let off = commands.begin()
        check(!commands.isCurrent(picker) && commands.isCurrent(off), "Late picker cannot undo OFF")
        let start = commands.begin(pendingTarget: true)
        let laterOff = commands.begin()
        commands.finish(start)
        check(commands.isCurrent(laterOff), "Activation wait cannot overwrite a later command")

        // Small bounded snapshots, no persistent device database or unbounded names.
        let many = (0..<100).map { _ in AccessoryAuthorization.Computer(id: UUID(), name: String(repeating: "a", count: 1000)) }
        restored.refresh([first, first] + many)
        check(restored.computers.count == 16, "Bound authorization snapshot")
        check(restored.computers.filter { $0.id == original }.count == 1, "Deduplicate identities")
        check(restored.computers.allSatisfy { $0.name.count <= 80 }, "Bound display names")
        print("PASS: \(checks) accessory authorization, migration, revocation, cold-start and control-race assertions.")
    }
}
