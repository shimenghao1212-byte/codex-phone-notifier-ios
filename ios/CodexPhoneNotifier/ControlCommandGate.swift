import Foundation

/// A later UI/control command wins while an earlier command awaits permissions.
struct ControlCommandGate {
    private var revision: UInt64 = 0
    private var pendingTarget: Bool?

    mutating func begin(pendingTarget: Bool? = nil) -> UInt64 {
        revision &+= 1
        self.pendingTarget = pendingTarget
        return revision
    }

    func isCurrent(_ command: UInt64) -> Bool { command == revision }

    func toggledTarget(current: Bool) -> Bool { !(pendingTarget ?? current) }

    mutating func finish(_ command: UInt64) {
        if isCurrent(command) { pendingTarget = nil }
    }
}

enum CodexModeError: String, LocalizedError {
    case chooseComputer = "请先在 Codex 提醒中选择一次电脑。"
    case bluetoothPermission = "请先在系统设置中允许 Codex 提醒使用蓝牙。"
    case accessoryPermission = "请打开 Codex 提醒，完成一次电脑授权后再开启。"
    case accessoryUnavailable = "系统正在检查电脑授权，请稍后再试。"
    case bluetoothOff = "请先打开 iPhone 蓝牙，再开启 Codex 模式。"
    case bluetoothUnsupported = "这台设备不支持蓝牙提醒。"
    case notificationPermission = "请先在系统通知设置中允许 Codex 提醒显示通知。"
    case superseded = "已采用你刚才的最新操作。"

    var errorDescription: String? { rawValue }
}
