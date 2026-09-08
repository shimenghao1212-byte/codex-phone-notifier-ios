import Foundation

enum ReportVoice: String, CaseIterable {
    case female, male
    var label: String { self == .female ? "女声" : "男声" }
    var asset: UInt8 { self == .female ? 16 : 17 }
}
struct ReportAudio: Codable, Equatable {
    let version: Int
    let segments: Int
    let codec: String
    var valid: Bool { version == 1 && (1...512).contains(segments) && codec == "mp3" }
    static let maximumBytes = 384 * 1024
}
enum AudioFailureDisposition: Equatable {
    case endPreview, nativeReport, skipReportRemainder
    static func resolve(preview: Bool, hasPlayed: Bool) -> Self {
        if preview { return .endPreview }
        return hasPlayed ? .skipReportRemainder : .nativeReport
    }
}
struct AudioSegmentRequest: Equatable {
    let id: UUID
    let asset: UInt8
    let segment: Int
    let token: UUID
    init(id: UUID, voice: ReportVoice, segment: Int) {
        self.id = id; asset = voice.asset; self.segment = segment; token = UUID()
    }
    var valid: Bool { (asset == 16 || asset == 17) && (0..<512).contains(segment) }
}
/// Tokens identify a particular clip attempt, not merely the report or segment.
/// Reset/replacement therefore makes every late callback harmless.
struct AudioRequestGate {
    private(set) var pending: AudioSegmentRequest?
    mutating func begin(_ request: AudioSegmentRequest) -> Bool {
        guard request.valid, pending == nil else { return false }
        pending = request; return true
    }
    mutating func accept(_ request: AudioSegmentRequest) -> Bool {
        guard pending == request else { return false }
        pending = nil; return true
    }
    mutating func reset() { pending = nil }
}
struct BoundedAudioRequests {
    private var items: [AudioSegmentRequest] = []
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    mutating func append(_ request: AudioSegmentRequest) -> Bool {
        guard request.valid, items.count < 2, !items.contains(where: { $0.token == request.token }) else { return false }
        items.append(request); return true
    }
    mutating func pop() -> AudioSegmentRequest? { items.isEmpty ? nil : items.removeFirst() }
    mutating func remove(token: UUID) { items.removeAll { $0.token == token } }
    mutating func reset() { items.removeAll() }
}
struct AudioPrefetchBuffer {
    private var clip: (index: Int, data: Data)?
    var isEmpty: Bool { clip == nil }
    var byteCount: Int { clip?.data.count ?? 0 }
    mutating func store(index: Int, data: Data) -> Bool {
        guard clip == nil, (0..<512).contains(index), !data.isEmpty,
              data.count <= ReportAudio.maximumBytes else { return false }
        clip = (index, data); return true
    }
    mutating func take() -> (index: Int, data: Data)? {
        let value = clip; clip = nil; return value
    }
    mutating func reset() { clip = nil }
}

struct ReportImage: Codable, Identifiable, Equatable {
    let index: Int
    let name: String
    var id: Int { index }
}
struct ReportMember: Codable, Equatable {
    let name: String
    let kind: UInt8
    var id: String? = nil
    var stableKey: String { id.map { "thread:" + $0 } ?? ("legacy:" + name) }
    var valid: Bool {
        !name.isEmpty && name.utf8.count <= 512 && (1...5).contains(kind)
            && (id == nil || (!id!.isEmpty && id!.utf8.count <= 128))
    }
}
struct ReportSection: Codable, Equatable {
    let member: Int
    let offset: Int
    let length: Int
    static func valid(_ sections: [Self], text: String, members: [ReportMember]) -> Bool {
        guard !sections.isEmpty, sections.count <= 32 else { return false }
        let bytes = Array(text.utf8)
        var previousEnd = 0
        for section in sections {
            guard members.indices.contains(section.member), section.offset >= previousEnd,
                  section.length > 0, section.offset <= bytes.count,
                  section.length <= bytes.count - section.offset else { return false }
            let end = section.offset + section.length
            guard String(bytes: bytes[section.offset..<end], encoding: .utf8) != nil else { return false }
            previousEnd = end
        }
        return true
    }
}
/// Stable across processes; Swift's randomized Hasher must not choose UI colors.
/// Resolve collisions deterministically among the current, bounded member list.
struct ThreadColorMap {
    static let palette: [UInt32] = [
        0xA7B8E8, 0x9DC7B7, 0xD9B998, 0xC5B1DB, 0xD9AAB7, 0x95C8CC, 0xC7CE9A, 0xA7C0D7,
        0xD2B2A0, 0xB5BEDE, 0xA9C8A2, 0xC8AFCA, 0x9DC8C2, 0xD0C0A4, 0xB0BAA3, 0xC0B7D9,
        0x8EA6D3, 0x89B6A3, 0xC4A481, 0xAF9AC6, 0xC592A1, 0x7FB6BB, 0xB4BB82, 0x90ABC3,
        0xBFA08D, 0x9EAACB, 0x94B78C, 0xB599B7, 0x85B5AF, 0xBCAC8F, 0x9CAB8D, 0xAC9FC5
    ]
    private var indices: [String: Int] = [:]
    static func preferredIndex(_ key: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(palette.count))
    }
    init(_ members: [ReportMember]) {
        var used: Set<Int> = []
        for key in Set(members.prefix(32).map(\.stableKey)).sorted() {
            var index = Self.preferredIndex(key)
            while used.contains(index) { index = (index + 1) % Self.palette.count }
            indices[key] = index; used.insert(index)
        }
    }
    func rgb(for member: ReportMember) -> UInt32 {
        Self.palette[indices[member.stableKey] ?? Self.preferredIndex(member.stableKey)]
    }
}
struct ReportBrief: Codable, Equatable {
    let id: UUID
    let kind: UInt8
    var heading: String
    var taskCount: Int
    var completedCount: Int
    var pausedCount: Int
    var members: [ReportMember]
    var mode: String?
    var namesSnippet: String { members.prefix(3).map(\.name).joined(separator: "、") }
    var valid: Bool {
        (1...5).contains(kind) && (1...1_000_000).contains(taskCount)
            && completedCount >= 0 && pausedCount >= 0
            && completedCount <= taskCount && pausedCount <= taskCount - completedCount
            && heading.utf8.count <= 512 && members.count <= 32
            && members.allSatisfy(\.valid)
            && (mode?.utf8.count ?? 0) <= 32
    }
    static func fallback(_ frame: EventFrame) -> Self {
        Self(id: frame.id, kind: frame.kind.rawValue, heading: frame.kind.label, taskCount: 1,
             completedCount: frame.kind == .turnEnded ? 1 : 0,
             pausedCount: frame.kind == .abnormalPaused ? 1 : 0, members: [], mode: nil)
    }
    static func decode(_ data: Data, expected: UUID) -> Self? {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.id == expected, value.valid else { return nil }
        return value
    }
}
struct PhoneReport: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, endedAt, text, truncated, images, heading, taskCount, completedCount, pausedCount, members, mode, audio, sections
    }
    let id: UUID
    let kind: UInt8
    let endedAt: Double
    var text: String
    var truncated: Bool
    var images: [ReportImage]
    var heading: String? = nil
    var taskCount: Int? = nil
    var completedCount: Int? = nil
    var pausedCount: Int? = nil
    var members: [ReportMember]? = nil
    var mode: String? = nil
    var audio: ReportAudio? = nil
    var sections: [ReportSection]? = nil
    var title: String { heading?.isEmpty == false ? heading! : (EventFrame.Kind(rawValue: kind)?.label ?? "Codex 提醒") }
    var brief: ReportBrief {
        ReportBrief(id: id, kind: kind, heading: title, taskCount: taskCount ?? 1,
                    completedCount: completedCount ?? (kind == 1 ? 1 : 0),
                    pausedCount: pausedCount ?? (kind == 3 ? 1 : 0), members: members ?? [], mode: mode)
    }
    mutating func apply(_ value: ReportBrief) {
        guard value.id == id else { return }
        heading = value.heading; taskCount = value.taskCount
        completedCount = value.completedCount; pausedCount = value.pausedCount
        members = value.members; mode = value.mode
    }

    mutating func replaceBodyWithFailure(_ message: String) {
        text = message
        // These values describe the old bytes/audio, not the replacement text.
        audio = nil
        sections = nil
        truncated = false
    }

    static func placeholder(_ frame: EventFrame) -> PhoneReport {
        PhoneReport(id: frame.id, kind: frame.kind.rawValue, endedAt: Date().timeIntervalSince1970,
                    text: "", truncated: false, images: [])
    }
    static func decode(_ data: Data, expected: UUID) -> PhoneReport? {
        guard data.count <= 96 * 1024,
              var value = try? JSONDecoder().decode(Self.self, from: data),
              value.id == expected, value.brief.valid,
              value.text.utf8.count <= 66 * 1024, value.images.count <= 4,
              Set(value.images.map(\.index)).count == value.images.count,
              value.images.allSatisfy({ (1...4).contains($0.index) && $0.name.utf8.count <= 1024 }) else { return nil }
        if value.audio?.valid == false { value.audio = nil }
        if let sections = value.sections, !ReportSection.valid(sections, text: value.text, members: value.members ?? []) {
            value.sections = nil
        }
        return value
    }
    var displaySections: [(member: ReportMember?, text: String, offset: Int)] {
        guard let sections, let members, ReportSection.valid(sections, text: text, members: members) else { return [] }
        let bytes = Array(text.utf8)
        var result: [(member: ReportMember?, text: String, offset: Int)] = []
        var end = 0
        for section in sections {
            let gap = String(decoding: bytes[end..<section.offset], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !gap.isEmpty { result.append((nil, gap, end)) }
            result.append((members[section.member], String(decoding: bytes[section.offset..<section.offset + section.length], as: UTF8.self), section.offset))
            end = section.offset + section.length
        }
        let tail = String(decoding: bytes[end...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append((nil, tail, end)) }
        return result
    }
}

extension PhoneReport {
    // Optional presentation metadata must never discard an otherwise valid reply.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(UInt8.self, forKey: .kind)
        endedAt = try values.decode(Double.self, forKey: .endedAt)
        text = try values.decode(String.self, forKey: .text)
        truncated = try values.decode(Bool.self, forKey: .truncated)
        images = try values.decode([ReportImage].self, forKey: .images)
        heading = try values.decodeIfPresent(String.self, forKey: .heading)
        taskCount = try values.decodeIfPresent(Int.self, forKey: .taskCount)
        completedCount = try values.decodeIfPresent(Int.self, forKey: .completedCount)
        pausedCount = try values.decodeIfPresent(Int.self, forKey: .pausedCount)
        members = try values.decodeIfPresent([ReportMember].self, forKey: .members)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        audio = try values.decodeIfPresent(ReportAudio.self, forKey: .audio)
        sections = try? values.decodeIfPresent([ReportSection].self, forKey: .sections)
    }
}

/// One call's metadata, replaced by event ID instead of counted twice.
struct CallReportBatch {
    private(set) var items: [ReportBrief] = []
    private(set) var rootID: UUID?
    private(set) var taskCount = 0
    private(set) var completedCount = 0
    private(set) var pausedCount = 0
    private var firstNames: [String] = []
    var namesSnippet: String { firstNames.joined(separator: "、") }
    var title: String { taskCount > 1 ? "Codex · \(taskCount) 个任务" : (items.first?.heading ?? "Codex 任务汇报") }
    func contains(_ id: UUID) -> Bool { items.contains { $0.id == id } }
    @discardableResult mutating func absorb(_ brief: ReportBrief) -> Bool {
        guard brief.valid else { return false }
        if let index = items.firstIndex(where: { $0.id == brief.id }) {
            let old = items[index]
            taskCount += brief.taskCount - old.taskCount
            completedCount += brief.completedCount - old.completedCount
            pausedCount += brief.pausedCount - old.pausedCount
            items[index] = brief
            for name in brief.members.map(\.name) where firstNames.count < 3 && !firstNames.contains(name) { firstNames.append(name) }
            return true
        }
        if rootID == nil { rootID = brief.id }
        taskCount += brief.taskCount; completedCount += brief.completedCount; pausedCount += brief.pausedCount
        for name in brief.members.map(\.name) where firstNames.count < 3 && !firstNames.contains(name) { firstNames.append(name) }
        if items.count == 32 { items.removeFirst() }
        items.append(brief); return true
    }
    mutating func reset() { items.removeAll(); rootID = nil; taskCount = 0; completedCount = 0; pausedCount = 0; firstNames.removeAll() }
}
struct SpeechPart { let id: UUID; let text: String }
/// Monotonic clocks only. Packet progress updates data, never allocates timers.
struct BodyWaitDeadline {
    let startedAt: TimeInterval
    private(set) var lastProgressAt: TimeInterval
    init(at now: TimeInterval) { startedAt = now; lastProgressAt = now }
    mutating func progress(at now: TimeInterval) { lastProgressAt = max(lastProgressAt, now) }
    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, min(startedAt + 120, lastProgressAt + 25) - now)
    }
}
/// Coalesce one damaged credit window until its replacement is actually written.
struct ReportRetryGate {
    private(set) var pending = false
    private(set) var ready = false
    var allowsWindow: Bool { !pending || ready }
    mutating func schedule() -> Bool {
        guard !pending else { return false }
        pending = true; ready = false; return true
    }
    mutating func release() { if pending { ready = true } }
    mutating func sent() { pending = false; ready = false }
}
struct BoundedSpeechQueue {
    private var pending: [SpeechPart] = []
    private var accepted: [UUID] = []
    private(set) var characterCount = 0
    private(set) var pendingBytes = 0
    private(set) var truncatedReports = 0
    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }
    func contains(_ id: UUID) -> Bool { accepted.contains(id) }
    @discardableResult mutating func enqueue(id: UUID, text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !accepted.contains(id), pending.count < 16 else { return false }
        var bounded = value
        if value.utf8.count > 64 * 1024 {
            bounded = String(decoding: value.utf8.prefix(64 * 1024 - 100), as: UTF8.self) + "。更多内容请查看手机或电脑。"
            truncatedReports += 1
        }
        guard pendingBytes + bounded.utf8.count <= 128 * 1024 else { return false }
        characterCount += bounded.count
        pendingBytes += bounded.utf8.count
        accepted.append(id); if accepted.count > 128 { accepted.removeFirst() }
        pending.append(SpeechPart(id: id, text: bounded)); return true
    }
    mutating func pop() -> SpeechPart? {
        guard !pending.isEmpty else { return nil }
        let result = pending.removeFirst(); characterCount -= result.text.count; pendingBytes -= result.text.utf8.count
        return result
    }
    mutating func reset() { pending.removeAll(); accepted.removeAll(); characterCount = 0; pendingBytes = 0; truncatedReports = 0 }
}

enum ReportWire {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        return crc
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (8 * $1)) }
    }
    static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func request(id: UUID, asset: UInt8, offset: Int, generation: UInt32) -> Data {
        var uuid = id.uuid
        var data = Data([0x43, 0x51, 2, asset])
        data.append(withUnsafeBytes(of: &uuid) { Data($0) })
        append(UInt32(offset), to: &data)
        append(generation, to: &data)
        return data
    }
    static func audioRequest(_ request: AudioSegmentRequest, offset: Int, generation: UInt32) -> Data {
        guard request.valid, offset >= 0, offset <= ReportAudio.maximumBytes else { return Data() }
        var uuid = request.id.uuid
        var data = Data([0x43, 0x51, 3, request.asset])
        data.append(withUnsafeBytes(of: &uuid) { Data($0) })
        append(UInt32(request.segment), to: &data)
        append(UInt32(offset), to: &data)
        append(generation, to: &data)
        return data
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return ~crc
    }
}
final class ReportAssembly {
    enum Result { case ignored, more, nextWindow, complete(Data), retry, failed }
    let asset: UInt8
    let generation: UInt32
    private(set) var bytes = Data()
    private var expectedTotal: Int?
    private var expectedCRC: UInt32?
    private var fragments = Data()
    private var nextFragment = 0
    private var waitingForFragmentStart = false
    init(asset: UInt8, generation: UInt32) {
        self.asset = asset
        self.generation = generation
    }
    var offset: Int { bytes.count }

    func accept(_ packet: Data) -> Result {
        if packet.count >= 2, packet[0] == 0x43, packet[1] == 0x46 {
            guard packet.count > 8 else { return .failed }
            guard ReportWire.u32(packet, 2) == generation else { return .ignored }
            let tag = Int(packet[6]) | (Int(packet[7]) << 8)
            let sequence = tag & 0x7fff
            let piece = Data(packet.dropFirst(8))
            if waitingForFragmentStart {
                guard sequence == 0 else { return .ignored }
                waitingForFragmentStart = false
            }
            if sequence == 0 && nextFragment > 0 && !fragments.starts(with: piece) {
                fragments.removeAll(keepingCapacity: true); nextFragment = 0
            }
            if sequence < nextFragment { return .ignored }
            guard sequence == nextFragment else {
                fragments.removeAll(keepingCapacity: true); nextFragment = 0
                waitingForFragmentStart = true; return .retry
            }
            guard sequence < 512, fragments.count + piece.count <= 512 else {
                fragments.removeAll(); nextFragment = 0; return .failed
            }
            fragments.append(piece); nextFragment += 1
            guard tag & 0x8000 != 0 else { return .more }
            let logical = fragments
            fragments.removeAll(keepingCapacity: true); nextFragment = 0
            return acceptLogical(logical)
        }
        return acceptLogical(packet)
    }
    private func acceptLogical(_ packet: Data) -> Result {
        guard packet.count >= 22, packet[0] == 0x43, packet[1] == 0x44, packet[2] == 2,
              packet[4] == asset, ReportWire.u32(packet, 6) == generation else { return .ignored }
        if packet[3] != 0 { return .failed }
        let offset = Int(ReportWire.u32(packet, 10))
        let total = Int(ReportWire.u32(packet, 14))
        let crc = ReportWire.u32(packet, 18)
        let maximum = (asset == 16 || asset == 17) ? ReportAudio.maximumBytes
            : (asset == 254 ? 4096 : (asset == 0 ? 96 * 1024 : 512 * 1024))
        guard total > 0, total <= maximum,
              packet.count > 22, offset <= total, packet.count - 22 <= total - offset else { return .failed }
        if let count = expectedTotal, count != total { return .failed }
        if let checksum = expectedCRC, checksum != crc { return .failed }
        expectedTotal = total; expectedCRC = crc
        if offset < bytes.count { return .ignored }
        if offset != bytes.count { return .retry }
        bytes.append(packet.dropFirst(22))
        if packet[5] & 2 != 0 {
            guard bytes.count == total, ReportWire.crc32(bytes) == crc else { return .failed }
            return .complete(bytes)
        }
        return packet[5] & 1 != 0 ? .nextWindow : .more
    }
}
