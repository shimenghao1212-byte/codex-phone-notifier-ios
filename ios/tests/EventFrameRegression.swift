import Foundation

@main
enum EventFrameRegression {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let valid: [UInt8] = [0x43, 0x4E, 1, 1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                              0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let cases: [(UInt8, EventFrame.Kind, String)] = [
            (1, .turnEnded, "任务结束了"),
            (2, .test, "测试已收到"),
            (3, .abnormalPaused, "异常暂停了"),
            (4, .question, "请回答问题"),
            (5, .custom, "Codex 消息"),
        ]
        for (byte, kind, title) in cases {
            var bytes = valid
            bytes[3] = byte
            let parsed = EventFrame(data: Data(bytes))!
            check(parsed.id == id, "UUID byte order for kind \(byte)")
            check(parsed.kind == kind, "Decoded event kind \(byte)")
            check(parsed.data == Data(bytes), "ACK retains all original bytes for kind \(byte)")
            check(EventFrame(id: id, kind: kind).data == Data(bytes), "20-byte wire v1 round trip")
            check(kind.label == title, "Notification and history title for kind \(byte)")
            check(EventFrame(data: Data([0x43, 0x4E, 1, byte] + Array(repeating: UInt8(0), count: 16))) == nil,
                  "Zero UUID is invalid for kind \(byte)")
        }
        check(EventFrame(data: Data()) == nil, "Empty data")
        check(EventFrame(data: Data(repeating: 0, count: 20)) == nil, "Empty cache")
        check(EventFrame(data: Data(valid.dropLast())) == nil, "Truncated packet")
        check(EventFrame(data: Data(valid + [0])) == nil, "Oversized packet")
        for (index, value) in [(0, UInt8(0)), (1, UInt8(0)), (2, UInt8(2)),
                               (3, UInt8(0)), (3, UInt8(6)), (3, UInt8(255))] {
            var bad = valid
            bad[index] = value
            check(EventFrame(data: Data(bad)) == nil, "Malformed or unsupported header")
        }

        // Existing v1.2 history used numeric kinds 1/2 and Foundation's default date encoding.
        let legacyHistory = Data("""
        [{"id":"00112233-4455-6677-8899-AABBCCDDEEFF","kind":1,"receivedAt":0,"delivery":"scheduled"},
         {"id":"10112233-4455-6677-8899-AABBCCDDEEFF","kind":2,"receivedAt":1,"delivery":"failed"}]
        """.utf8)
        let restored = try JSONDecoder().decode([EventRecord].self, from: legacyHistory)
        check(restored.count == 2 && restored[0].kind == .turnEnded && restored[1].kind == .test,
              "Legacy history remains readable without migration")
        check(restored[0].id == id && restored[0].delivery == .scheduled && restored[1].delivery == .failed,
              "Legacy history preserves IDs and delivery states")
        let pause = EventRecord(id: id, kind: .abnormalPaused,
                                receivedAt: Date(timeIntervalSinceReferenceDate: 2), delivery: .scheduled)
        let roundTrip = try JSONDecoder().decode(EventRecord.self, from: JSONEncoder().encode(pause))
        check(roundTrip.id == pause.id && roundTrip.kind == .abnormalPaused &&
              roundTrip.receivedAt == pause.receivedAt && roundTrip.delivery == .scheduled,
              "Pause history survives persistence with its original identity")
        print("PASS: \(checks) EventFrame protocol, title and history checks")
    }
}
