import AppIntents
import Foundation

struct SetCodexModeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "设置 Codex 模式"
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Codex 模式")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CODEX_CONTROL_EXTENSION
        let message = try CodexControlRoutingError.requireHost()
        #else
        let message = try await BluetoothReceiver.shared.setListeningFromControl(value)
        #endif
        return .result(dialog: "\(message)")
    }
}

// Both targets expose the same intent identity. Only the host owns a BLE manager.
struct ToggleCodexModeIntent: AppIntent {
    static let title: LocalizedStringResource = "切换 Codex 模式"
    static let description = IntentDescription("开启或暂停 Codex 蓝牙提醒。")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CODEX_CONTROL_EXTENSION
        // Never silently succeed in the wrong process or create a second receiver.
        let message = try CodexControlRoutingError.requireHost()
        #else
        let message = try await BluetoothReceiver.shared.toggleListeningFromControl()
        #endif
        return .result(dialog: "\(message)")
    }
}

private enum CodexControlRoutingError: LocalizedError {
    case hostRequired
    static func requireHost() throws -> String { throw Self.hostRequired }
    var errorDescription: String? {
        "系统未能启动 Codex 提醒。请打开 App 一次后重试。"
    }
}

// This conformance routes execution into the host, starting in the background.
// It is unavailable to extensions; no foreground continuation is requested.
#if !CODEX_CONTROL_EXTENSION
extension SetCodexModeIntent: ForegroundContinuableIntent {}
extension ToggleCodexModeIntent: ForegroundContinuableIntent {}

struct CodexModeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleCodexModeIntent(),
            phrases: ["切换 \(.applicationName) 模式"],
            shortTitle: "Codex 模式",
            systemImageName: "terminal"
        )
    }
}
#endif
