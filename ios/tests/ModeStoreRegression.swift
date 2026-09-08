import Foundation

@main
struct ModeStoreRegression {
    static func expect(_ value: Bool, _ message: String = "") { precondition(value, message) }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = CodexModeStore(directory: folder)
        let control = CodexModeStore(directory: folder)
        do { _ = try control.read(); fatalError("Missing state must not pretend to be off") }
        catch CodexModeStoreError.notInitialized {}
        try expect(host.write(false))
        try expect(!control.read())
        try expect(host.write(true))
        try expect(control.read(), "Control must observe App changes")
        try expect(!host.write(true), "No write/reload when state is unchanged")
        try expect(host.write(false))
        try expect(!control.read(), "Off survives a new store instance")
        try Data("broken".utf8).write(to: folder.appendingPathComponent("codex-mode-v1.json"))
        do { _ = try control.read(); fatalError("Corrupt state must not show a fake state") }
        catch CodexModeStoreError.invalidState {}
        try expect(host.write(true), "Host repairs corrupt shared state")
        try expect(control.read())
        let unavailable = CodexModeStore(directory: nil)
        do { _ = try unavailable.write(true); fatalError("Missing entitlement must fail") }
        catch CodexModeStoreError.unavailable {}
        print("PASS: shared on/off persistence, cross-instance reads, no redundant writes, corruption recovery, missing entitlement.")
    }
}
