import Foundation

enum CodexModeStoreError: LocalizedError {
    case unavailable, notInitialized, invalidState
    var errorDescription: String? {
        switch self {
        case .unavailable: return "控件共享权限不可用，请保留 App Groups 权限重新签名安装。"
        case .notInitialized: return "请打开 Codex 提醒一次，完成控制中心状态初始化。"
        case .invalidState: return "控制中心状态无法读取，请打开 Codex 提醒修复。"
        }
    }
}

/// One tiny atomic file: the host is the only writer; the control only reads.
/// This records whether receiving is enabled, not whether the PC is connected.
struct CodexModeStore {
    static let kind = "local.codex.phone.controls.mode"
    static let group = "group.local.codex.phone.notifier"
    static let live = CodexModeStore(directory: resolveContainer())
    let directory: URL?

    private struct State: Codable, Equatable {
        var schema = 1
        var enabled: Bool
    }

    private var file: URL? { directory?.appendingPathComponent("codex-mode-v1.json") }
    var isAvailable: Bool { directory != nil }

    func read() throws -> Bool {
        guard let file else { throw CodexModeStoreError.unavailable }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CodexModeStoreError.notInitialized
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4096 else { throw CodexModeStoreError.invalidState }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: file)),
              state.schema == 1 else { throw CodexModeStoreError.invalidState }
        return state.enabled
    }

    /// False means the persisted value was already correct; no write/reload needed.
    @discardableResult
    func write(_ enabled: Bool) throws -> Bool {
        guard let file else { throw CodexModeStoreError.unavailable }
        if (try? read()) == enabled { return false }
        let data = try JSONEncoder().encode(State(enabled: enabled))
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return true
    }

    private static func resolveContainer() -> URL? {
        // Resigning tools may append a team suffix to the group ID. Use only this
        // app's matching group declared by the installed, OS-validated profile.
        var candidates: [String] = []
        if let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profile), data.count < 2_000_000,
           let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil
           ) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            candidates = groups.filter { $0 == group || $0.hasPrefix(group + ".") }
        }
        candidates.append(group) // App Store / unrenamed provisioning fallback.
        for candidate in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                return url
            }
        }
        return nil
    }
}
