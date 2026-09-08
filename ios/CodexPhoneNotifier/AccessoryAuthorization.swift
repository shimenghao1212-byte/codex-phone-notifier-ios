import Foundation

/// Authorization belongs to the OS. Never persist a second, potentially stale permission flag.
/// This small reducer also enforces Apple's prohibition on starting CoreBluetooth mid-migration.
struct AccessoryAuthorization {
    /// Check before ASAccessorySession.init: missing runtime declaration is a
    /// fatal framework assertion, not a recoverable activation error.
    static func supportsBluetooth(info: [String: Any], serviceUUID: String) -> Bool {
        guard info["NSAccessorySetupSupports"] as? [String] == ["Bluetooth"],
              info["NSAccessorySetupKitSupports"] as? [String] == ["Bluetooth"],
              let services = info["NSAccessorySetupBluetoothServices"] as? [String] else { return false }
        return services.contains(serviceUUID.uppercased())
    }

    struct Computer: Equatable {
        let id: UUID
        let name: String
    }
    enum Phase { case loading, ready, failed }
    private(set) var phase = Phase.loading
    private(set) var computers: [Computer] = []
    private(set) var pickerActive = false
    private(set) var migrationID: UUID?
    private(set) var centralCreated = false

    init(centralAlreadyCreated: Bool = false) { centralCreated = centralAlreadyCreated }

    mutating func refresh(_ authorized: [Computer]) {
        phase = .ready
        var seen: Set<UUID> = []
        computers = authorized.filter { seen.insert($0.id).inserted }.prefix(16).map {
            Computer(id: $0.id, name: String($0.name.prefix(80)))
        }
    }

    func permits(_ id: UUID?) -> Bool {
        guard phase == .ready, migrationID == nil, let id else { return false }
        return computers.contains { $0.id == id }
    }

    mutating func claimCentral(for id: UUID?) -> Bool {
        guard !centralCreated, permits(id) else { return false }
        centralCreated = true
        return true
    }

    mutating func beginPicker(selected: UUID?) -> Bool {
        guard phase == .ready, !pickerActive else { return false }
        // Once any manager has existed in this process, use discovery, never migration.
        migrationID = !centralCreated && !permits(selected) ? selected : nil
        pickerActive = true
        return true
    }

    mutating func migrationCompleted() { migrationID = nil }

    mutating func finishPicker() {
        if let incomplete = migrationID {
            // An accessoryAdded callback alone cannot complete a migration.
            computers.removeAll { $0.id == incomplete }
        }
        migrationID = nil
        pickerActive = false
    }

    mutating func invalidate() {
        phase = .failed
        computers.removeAll()
        migrationID = nil
        pickerActive = false
    }
}
