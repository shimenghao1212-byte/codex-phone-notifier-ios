import Foundation
import CoreBluetooth

@main
struct BluetoothRecoveryRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool) {
        precondition(value(), "Bluetooth recovery regression failed at check \(checks + 1)")
        checks += 1
    }
    static func main() {
        // Test the complete dictionary handed to central.connect, not a second
        // implementation of the delay conversion in the test.
        var immediateKeys: Set<String> = []
        if #available(iOS 17.0, macOS 14.0, *) {
            immediateKeys.insert(CBConnectPeripheralOptionEnableAutoReconnect)
            check(BluetoothConnectionOptions.make(delay: 0)[CBConnectPeripheralOptionEnableAutoReconnect] as? Bool == true)
        }
        for delay in [0.0, -0.0, -1, -30, Double.nan, Double.infinity, -Double.infinity] {
            let options = BluetoothConnectionOptions.make(delay: delay)
            check(Set(options.keys) == immediateKeys)
            check(options[CBConnectPeripheralOptionStartDelayKey] == nil)
        }
        let positiveDelays: [(TimeInterval, UInt32)] = [
            (.leastNonzeroMagnitude, 1), (0.001, 1), (1, 1), (1.5, 2),
            (2, 2), (4, 4), (8, 8), (16, 16), (29.1, 30),
            (30, 30), (30.5, 30), (.greatestFiniteMagnitude, 30)
        ]
        for (delay, expected) in positiveDelays {
            let options = BluetoothConnectionOptions.make(delay: delay)
            check(Set(options.keys) == immediateKeys.union([CBConnectPeripheralOptionStartDelayKey]))
            guard let number = options[CBConnectPeripheralOptionStartDelayKey] as? NSNumber else {
                preconditionFailure("Connection delay must be NSNumber")
            }
            check(number.uint32Value == expected)
            check(number.doubleValue == Double(expected))
            check(!["f", "d"].contains(String(cString: number.objCType)))
            if #available(iOS 17.0, macOS 14.0, *) {
                check(options[CBConnectPeripheralOptionEnableAutoReconnect] as? Bool == true)
            }
        }

        var recovery = BluetoothRecovery()
        check(recovery.takeConnectDelay(at: 10) == 0)
        check(recovery.takeConnectDelay(at: 10) == nil) // State can lag behind connect().
        recovery.connected()
        recovery.reset() // Subscription succeeded.

        // Connected setup fails while the screen is off. Cancel first, then
        // immediately hand the remaining delay to the system; no timer fires.
        check(recovery.fail(at: 100, disconnected: false) == 2)
        check(recovery.isCancelling)
        check(recovery.takeConnectDelay(at: 100) == nil)
        check(recovery.fail(at: 101, disconnected: false) == nil)
        check(recovery.retryDeadline == 102 && recovery.attempt == 1)
        check(!recovery.connectionFailed(at: 101, disconnected: true)) // Cancellation must not reset backoff.
        check(recovery.disconnected(systemReconnecting: false))
        check(recovery.takeConnectDelay(at: 100.5) == 1.5)
        check(!recovery.connectionFailed(at: 101, disconnected: false)) // Another OS attempt is already connecting.
        check(recovery.retryDeadline == 102 && recovery.attempt == 1)
        // The app can now remain suspended indefinitely; the pending request is
        // owned by CoreBluetooth. Duplicate callbacks do not resubmit it.
        check(!recovery.disconnected(systemReconnecting: false))
        check(recovery.takeConnectDelay(at: 500) == nil)
        recovery.connected()
        check(recovery.retryDeadline == nil && recovery.attempt == 1)
        check(recovery.fail(at: 501, disconnected: false) == 4)
        check(recovery.disconnected(systemReconnecting: false))
        check(recovery.takeConnectDelay(at: 507) == 0) // Already elapsed, no extra wait.

        // A failed pending connection gets new bounded backoff, independent of
        // whether foreground/restore callbacks were received between attempts.
        for (index, expected) in [8.0, 16.0, 30.0, 30.0, 30.0].enumerated() {
            let now = 510.0 + Double(index) * 40
            check(recovery.connectionFailed(at: now, disconnected: true))
            check(recovery.fail(at: now, disconnected: true) == expected)
            check(recovery.takeConnectDelay(at: now) == expected)
            check(recovery.takeConnectDelay(at: now + 1) == nil)
        }
        check(recovery.attempt == 5)

        // Pause, choosing another computer and radio-off all reset the policy.
        recovery.reset()
        check(recovery.attempt == 0 && recovery.retryDeadline == nil && !recovery.isCancelling)
        check(recovery.takeConnectDelay(at: 900) == 0)
        recovery.connected()
        check(!recovery.disconnected(systemReconnecting: true))
        check(recovery.takeConnectDelay(at: 901) == nil) // Never fight system auto-reconnect.
        recovery.connected()
        check(recovery.disconnected(systemReconnecting: false))
        check(recovery.takeConnectDelay(at: 902) == 0) // Normal link loss: one immediate request.
        recovery.reset()
        recovery.adoptPendingConnection() // State restoration already has a pending connect.
        check(recovery.takeConnectDelay(at: 950) == nil)
        recovery.connected()
        recovery.reset()
        check(recovery.fail(at: 1000, disconnected: true) == 2)
        check(recovery.takeConnectDelay(at: 1000) == 2)
        // A delayed request can fail immediately. didFailToConnect is terminal;
        // ignoring it until the deadline would leave no system request to wake us.
        check(recovery.connectionFailed(at: 1000.1, disconnected: true))
        check(recovery.fail(at: 1000.1, disconnected: true) == 4)
        check(recovery.takeConnectDelay(at: 1000.1) == 4)
        check(recovery.earlyRejections == 1 && !recovery.pausedByRejections)
        check(recovery.connectionFailed(at: 1000.2, disconnected: true))
        check(recovery.fail(at: 1000.2, disconnected: true) == 8)
        check(recovery.takeConnectDelay(at: 1000.2) == 8)
        check(recovery.connectionFailed(at: 1000.3, disconnected: true))
        check(recovery.earlyRejections == 3 && recovery.pausedByRejections)
        check(recovery.retryDeadline == nil) // No fabricated pending system request remains.
        check(recovery.fail(at: 2000, disconnected: true) == nil)
        check(recovery.takeConnectDelay(at: 2000) == nil)
        check(!recovery.connectionFailed(at: 2000, disconnected: true))
        check(!recovery.disconnected(systemReconnecting: false))
        recovery.adoptPendingConnection()
        check(recovery.takeConnectDelay(at: 2000) == nil)
        recovery.reset() // Explicit user restart/radio transition can try again.
        check(!recovery.pausedByRejections && recovery.earlyRejections == 0)
        check(recovery.fail(at: 2000, disconnected: true) == 2)
        check(recovery.takeConnectDelay(at: 2000) == 2)
        check(recovery.connectionFailed(at: 2000.1, disconnected: true))
        check(recovery.earlyRejections == 1)
        check(recovery.fail(at: 2000.1, disconnected: true) == 4)
        check(recovery.takeConnectDelay(at: 2000.1) == 4)
        check(recovery.connectionFailed(at: 2005, disconnected: true)) // Real delayed failure breaks the rejection streak.
        check(recovery.earlyRejections == 0 && !recovery.pausedByRejections)
        check(recovery.fail(at: 2005, disconnected: true) == 8)
        check(recovery.takeConnectDelay(at: 2005) == 8)
        check(recovery.connectionFailed(at: 2005.1, disconnected: true))
        recovery.connected()
        check(recovery.earlyRejections == 0 && !recovery.pausedByRejections && recovery.retryDeadline == nil)

        func entry(_ time: Double, _ event: BluetoothDiagnostics.Event = .disconnected,
                   error: Int? = 6, reconnecting: Bool = false) -> BluetoothDiagnostics.Entry {
            .init(time: time, event: event, radio: 5, link: 0, application: 2,
                  error: error, reconnecting: reconnecting)
        }
        var diagnostics = BluetoothDiagnostics()
        check(diagnostics.append(entry(100)))
        check(!diagnostics.append(entry(101))) // Duplicate status causes no defaults write.
        for index in 0..<100 {
            check(diagnostics.append(entry(102 + Double(index), index % 2 == 0 ? .connected : .disconnected)))
        }
        check(diagnostics.entries.count == 12)
        let encoded = diagnostics.encoded()!
        check(encoded.count <= 4096)
        let restored = BluetoothDiagnostics(data: encoded)
        check(restored.entries == diagnostics.entries)
        check(BluetoothDiagnostics(data: Data(repeating: 0, count: 4097)).entries.isEmpty)
        check(BluetoothDiagnostics(data: Data("invalid".utf8)).entries.isEmpty)
        check(!diagnostics.append(entry(.infinity)))
        let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let rows = object["entries"] as! [[String: Any]]
        check(rows.allSatisfy { Set($0.keys) == Set(["time", "event", "radio", "link", "application", "error", "reconnecting"]) })
        // Existing 1.8.1 JSON has no errorDomain; synthesized optional decoding
        // must retain its entries and preserve nil when loading that history.
        let legacy = Data("{\"entries\":[{\"time\":100,\"event\":\"failed\",\"radio\":5,\"link\":0,\"application\":0,\"error\":1,\"reconnecting\":false}]}".utf8)
        let legacyRestored = BluetoothDiagnostics(data: legacy)
        check(legacyRestored.entries.count == 1)
        check(legacyRestored.entries[0].errorDomain == nil)
        check(legacyRestored.entries[0].error == 1)
        var domains = BluetoothDiagnostics()
        for domain in ["cb", "att", "other"] {
            var row = entry(200, .failed, error: 1)
            row.errorDomain = domain
            check(domains.append(row)) // Different categories must not deduplicate.
        }
        let domainData = domains.encoded()!
        let domainObject = try! JSONSerialization.jsonObject(with: domainData) as! [String: Any]
        let domainRows = domainObject["entries"] as! [[String: Any]]
        check(domainRows.allSatisfy { Set($0.keys) == FIELDS_WITH_DOMAIN })
        check(domainRows.compactMap { $0["errorDomain"] as? String } == ["cb", "att", "other"])
        check(BluetoothDiagnostics(data: domainData).entries == domains.entries)
        var privateDomain = entry(201, .failed, error: 2)
        privateDomain.errorDomain = "UnboundedPrivateDomain"
        check(domains.append(privateDomain))
        check(domains.entries.last?.errorDomain == "other")
        check(!String(decoding: domains.encoded()!, as: UTF8.self).contains("UnboundedPrivateDomain"))
        let unknownDomain = Data("{\"entries\":[{\"time\":100,\"event\":\"failed\",\"radio\":5,\"application\":0,\"reconnecting\":false,\"errorDomain\":\"UnboundedPrivateDomain\"}]}".utf8)
        check(BluetoothDiagnostics(data: unknownDomain).entries.first?.errorDomain == "other")
        print("PASS: \(checks) Bluetooth recovery assertions; connection options, system-owned delay, duplicate callbacks, restoration and bounded diagnostics.")
    }

    static let FIELDS_WITH_DOMAIN: Set<String> = ["time", "event", "radio", "link", "application", "error", "reconnecting", "errorDomain"]
}
