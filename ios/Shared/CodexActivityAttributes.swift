import ActivityKit
import Foundation

/// Small, result-only content shared by the App and its Widget Extension.
struct CodexActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case ready, disconnected, turnEnded, test
        }

        var phase: Phase
        var isConnected: Bool
        var latestMessage: String
        var receivedAt: Date?
        var count: Int
        var lastEventID: UUID?
    }

    let sessionID: UUID
    let startedAt: Date
}
