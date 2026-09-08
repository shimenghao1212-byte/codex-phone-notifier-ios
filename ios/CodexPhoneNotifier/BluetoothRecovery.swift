import Foundation
import CoreBluetooth

/// Keep immediate connections identical to the working no-delay options.
/// Positive backoff remains owned by CoreBluetooth while the app is suspended.
enum BluetoothConnectionOptions {
    static func make(delay: TimeInterval) -> [String: Any] {
        var options: [String: Any] = [:]
        if #available(iOS 17.0, macOS 14.0, *) {
            options[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }
        if delay.isFinite, delay > 0 {
            let seconds = UInt32(min(delay, 30).rounded(.up))
            options[CBConnectPeripheralOptionStartDelayKey] = NSNumber(value: seconds)
        }
        return options
    }
}

/// A reconnect is either owned by CoreBluetooth or waiting for its cancellation
/// callback. No application timer is needed while iOS suspends the receiver.
struct BluetoothRecovery {
    private enum Phase { case idle, cancelling, requested, automatic }
    private var phase = Phase.idle
    private(set) var attempt = 0
    private(set) var retryDeadline: TimeInterval?
    private var submittedStartDeadline: TimeInterval?
    private(set) var earlyRejections = 0
    private(set) var pausedByRejections = false
    var isCancelling: Bool { phase == .cancelling }

    mutating func fail(at now: TimeInterval, disconnected: Bool) -> TimeInterval? {
        guard !pausedByRejections, retryDeadline == nil else { return nil }
        attempt = min(attempt + 1, 5)
        let delay = min(pow(2.0, Double(attempt)), 30)
        retryDeadline = now + delay
        phase = disconnected ? .idle : .cancelling
        return delay
    }

    /// Consume once before calling central.connect, even if CBPeripheral.state
    /// has not yet changed. Duplicate callbacks cannot submit a second request.
    mutating func takeConnectDelay(at now: TimeInterval) -> TimeInterval? {
        guard !pausedByRejections, phase == .idle else { return nil }
        phase = .requested
        let delay = max(0, (retryDeadline ?? now) - now)
        submittedStartDeadline = now + delay
        return delay
    }

    mutating func disconnected(systemReconnecting: Bool) -> Bool {
        guard !pausedByRejections else { return false }
        if phase == .cancelling { phase = .idle; return true }
        if phase == .requested { return false } // A prior disconnect was already handled.
        if systemReconnecting { phase = .automatic; return false }
        phase = .idle
        return true
    }

    mutating func adoptPendingConnection() {
        if !pausedByRejections, phase == .idle { phase = .requested }
    }

    mutating func connected() {
        phase = .idle
        retryDeadline = nil // Discovery may run; only subscription success resets backoff.
        submittedStartDeadline = nil
        earlyRejections = 0
        pausedByRejections = false
    }

    /// didFailToConnect completes a pending request; the next real failure gets
    /// a fresh backoff. A cancellation of failed discovery keeps its deadline.
    mutating func connectionFailed(at now: TimeInterval, disconnected: Bool) -> Bool {
        // Preserve a newer connecting owner or cancellation in progress. A
        // disconnected failure is terminal even before a requested start delay:
        // the system may reject the request immediately, leaving nothing pending.
        guard disconnected, phase != .cancelling, !pausedByRejections else { return false }
        if let deadline = submittedStartDeadline, now < deadline {
            earlyRejections = min(earlyRejections + 1, 3)
        } else { earlyRejections = 0 }
        phase = .idle
        retryDeadline = nil
        submittedStartDeadline = nil
        // Every failure is terminal, including early rejections. If the OS
        // repeatedly rejects its own delay, stop instead of spinning callbacks.
        pausedByRejections = earlyRejections >= 3
        return true
    }

    mutating func reset() { self = Self() }
}

/// Small, payload-free history written only when connection state changes.
/// Never records task text, peripheral names/UUIDs, or localized error messages.
struct BluetoothDiagnostics: Codable {
    enum Event: String, Codable {
        case started, stopped, radio, restored, connected, ready, disconnected, failed, retry
        case launched, controlOn, controlOff, authorized, authorizationLost
    }
    struct Entry: Codable, Equatable {
        let time: TimeInterval
        let event: Event
        let radio: Int
        let link: Int?
        let application: Int
        let error: Int?
        let reconnecting: Bool
        var errorDomain: String? = nil
        func sanitized() -> Self {
            var value = self
            if let domain = value.errorDomain, domain != "cb", domain != "att", domain != "other" {
                value.errorDomain = "other"
            }
            return value
        }
        func sameState(as other: Self) -> Bool {
            event == other.event && radio == other.radio && link == other.link
                && application == other.application && error == other.error && reconnecting == other.reconnecting
                && errorDomain == other.errorDomain
        }
    }
    static let maximumEntries = 12
    static let maximumBytes = 4096
    private(set) var entries: [Entry] = []
    init(data: Data? = nil) {
        if let data, data.count <= Self.maximumBytes,
           let restored = try? JSONDecoder().decode(Self.self, from: data) {
            entries = restored.entries.suffix(Self.maximumEntries).map { $0.sanitized() }
        }
    }
    @discardableResult mutating func append(_ value: Entry) -> Bool {
        let sanitized = value.sanitized()
        guard sanitized.time.isFinite, entries.last?.sameState(as: sanitized) != true else { return false }
        entries.append(sanitized)
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
        return true
    }
    func encoded() -> Data? {
        guard let value = try? JSONEncoder().encode(self), value.count <= Self.maximumBytes else { return nil }
        return value
    }
}
