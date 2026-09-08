import Foundation

/// Wire format: ASCII CN, version 1, kind, 16 UUID bytes in RFC 4122 order.
/// The sender must not use .NET Guid.ToByteArray()'s default mixed-endian order.
struct EventFrame: Equatable {
    enum Kind: UInt8, Codable {
        case turnEnded = 1
        case test = 2
        case abnormalPaused = 3
        case question = 4
        case custom = 5

        var label: String {
            switch self {
            case .turnEnded: return "任务结束了"
            case .test: return "测试已收到"
            case .abnormalPaused: return "异常暂停了"
            case .question: return "请回答问题"
            case .custom: return "Codex 消息"
            }
        }
        var message: String {
            switch self {
            case .turnEnded: return "任务已结束，请查看电脑上的结果"
            case .test: return "蓝牙测试提醒"
            case .abnormalPaused: return "任务异常暂停，请查看电脑上的状态"
            case .question: return "Codex 正在等你选择或输入答案，请回到电脑回答问题。"
            case .custom: return "收到一条 Codex 消息，请查看汇报。"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let data: Data

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 20,
              bytes[0] == 0x43, bytes[1] == 0x4E, bytes[2] == 1,
              let kind = Kind(rawValue: bytes[3]),
              bytes[4...19].contains(where: { $0 != 0 }) else { return nil }
        self.id = UUID(uuid: (
            bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19]
        ))
        self.kind = kind
        self.data = data
    }

    init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
        var value = id.uuid
        self.data = Data([0x43, 0x4E, 1, kind.rawValue]) + withUnsafeBytes(of: &value) { Data($0) }
    }
}

struct EventRecord: Codable, Identifiable {
    enum Delivery: String, Codable {
        case awaitingPermission, failed, scheduled, requestedCall

        var label: String {
            switch self {
            case .awaitingPermission: return "尚未开启通知"
            case .failed: return "提交通知失败"
            case .scheduled: return "已提交系统提醒"
            case .requestedCall: return "已请求来电"
            }
        }
    }
    let id: UUID
    let kind: EventFrame.Kind
    let receivedAt: Date
    var delivery: Delivery
}
