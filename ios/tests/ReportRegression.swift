import Foundation

@main
struct ReportRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool) {
        precondition(value(), "Report regression failed at check \(checks + 1)")
        checks += 1
    }
    static func frame(_ bytes: Data, offset: Int, total: Int, crc: UInt32, flags: UInt8, gen: UInt32 = 7, asset: UInt8 = 0) -> Data {
        var data = Data([0x43, 0x44, 2, 0, asset, flags])
        for value in [gen, UInt32(offset), UInt32(total), crc] { ReportWire.append(value, to: &data) }
        return data + bytes
    }
    static func main() {
        let id = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        var failedBody = PhoneReport(id: id, kind: 1, endedAt: 1, text: "原始正文", truncated: true,
                                     images: [], members: [ReportMember(name: "任务甲", kind: 1)],
                                     audio: ReportAudio(version: 1, segments: 2, codec: "mp3"),
                                     sections: [ReportSection(member: 0, offset: 0, length: 12)])
        failedBody.replaceBodyWithFailure("完整汇报暂未收到，请查看电脑。")
        check(failedBody.text == "完整汇报暂未收到，请查看电脑。")
        check(failedBody.audio == nil && failedBody.sections == nil && !failedBody.truncated)
        check(failedBody.members?.first?.name == "任务甲" && failedBody.id == id)
        let reloadedFailure = PhoneReport.decode(try! JSONEncoder().encode(failedBody), expected: id)
        check(reloadedFailure == failedBody && reloadedFailure?.audio == nil && reloadedFailure?.displaySections.isEmpty == true)
        let request = ReportWire.request(id: id, asset: 2, offset: 0x01020304, generation: 7)
        check(request.count == 28)
        check(Array(request.prefix(4)) == [0x43,0x51,2,2])
        check(Array(request[20..<24]) == [4,3,2,1])
        let femaleClip = AudioSegmentRequest(id: id, voice: .female, segment: 0)
        let maleClip = AudioSegmentRequest(id: id, voice: .male, segment: 511)
        let audioRequest = ReportWire.audioRequest(maleClip, offset: 0x010203, generation: 0x08070605)
        check(audioRequest.count == 32 && Array(audioRequest.prefix(4)) == [0x43, 0x51, 3, 17])
        check(audioRequest[4..<20] == request[4..<20])
        check(ReportWire.u32(audioRequest, 20) == 511 && ReportWire.u32(audioRequest, 24) == 0x010203)
        check(ReportWire.u32(audioRequest, 28) == 0x08070605)
        check(ReportWire.audioRequest(femaleClip, offset: 0, generation: 7)[3] == 16)
        check(ReportWire.audioRequest(femaleClip, offset: -1, generation: 7).isEmpty)
        check(ReportWire.audioRequest(femaleClip, offset: ReportAudio.maximumBytes + 1, generation: 7).isEmpty)
        check(ReportWire.audioRequest(AudioSegmentRequest(id: id, voice: .male, segment: 512), offset: 0, generation: 7).isEmpty)
        check(!AudioSegmentRequest(id: id, voice: .male, segment: -1).valid)
        // A failed preview may neither read the full report nor substitute another voice.
        check(AudioFailureDisposition.resolve(preview: true, hasPlayed: false) == .endPreview)
        check(AudioFailureDisposition.resolve(preview: true, hasPlayed: true) == .endPreview)
        check(AudioFailureDisposition.resolve(preview: false, hasPlayed: false) == .nativeReport)
        check(AudioFailureDisposition.resolve(preview: false, hasPlayed: true) == .skipReportRemainder)
        var audioGate = AudioRequestGate()
        check(audioGate.begin(femaleClip) && !audioGate.begin(maleClip))
        check(!audioGate.accept(maleClip) && audioGate.pending == femaleClip)
        audioGate.reset() // A hangup invalidates even a completed packet queued on the main thread.
        check(!audioGate.accept(femaleClip) && audioGate.pending == nil)
        let replacementClip = AudioSegmentRequest(id: id, voice: .female, segment: 0)
        check(audioGate.begin(replacementClip) && !audioGate.accept(femaleClip))
        check(audioGate.accept(replacementClip) && !audioGate.accept(replacementClip))
        var audioRequests = BoundedAudioRequests()
        check(audioRequests.append(femaleClip) && !audioRequests.append(femaleClip))
        check(audioRequests.append(maleClip) && !audioRequests.append(replacementClip) && audioRequests.count == 2)
        audioRequests.remove(token: femaleClip.token)
        check(audioRequests.pop() == maleClip && audioRequests.isEmpty)
        check(!audioRequests.append(AudioSegmentRequest(id: id, voice: .male, segment: 512)))
        check(audioRequests.append(replacementClip)); audioRequests.reset(); check(audioRequests.isEmpty)
        var prefetch = AudioPrefetchBuffer()
        check(!prefetch.store(index: 0, data: Data()) && prefetch.isEmpty)
        check(!prefetch.store(index: 0, data: Data(repeating: 0, count: ReportAudio.maximumBytes + 1)))
        check(!prefetch.store(index: 512, data: Data([1])))
        check(prefetch.store(index: 0, data: Data(repeating: 1, count: ReportAudio.maximumBytes)))
        check(prefetch.byteCount == ReportAudio.maximumBytes && !prefetch.store(index: 1, data: Data([2])))
        check(prefetch.take()?.index == 0 && prefetch.isEmpty && prefetch.byteCount == 0)
        check(prefetch.store(index: 511, data: Data([3]))); prefetch.reset(); check(prefetch.take() == nil)
        check(ReportWire.crc32(Data("123456789".utf8)) == 0xcbf43926)
        let text = Data("本次任务完成🙂".utf8)
        let crc = ReportWire.crc32(text)
        let receiver = ReportAssembly(asset: 0, generation: 7)
        if case .ignored = receiver.accept(frame(text, offset: 0, total: text.count, crc: crc, flags: 3, gen: 6)) {} else { fatalError("Stale transfer accepted") }
        check(receiver.offset == 0)
        let first = frame(Data(text.prefix(8)), offset: 0, total: text.count, crc: crc, flags: 1)
        if case .nextWindow = receiver.accept(first) {} else { fatalError("Expected window") }
        check(receiver.offset == 8)
        if case .ignored = receiver.accept(first) {} else { fatalError("Duplicate appended") }
        if case .retry = receiver.accept(frame(Data(text.suffix(3)), offset: text.count-3, total: text.count, crc: crc, flags: 3)) {} else { fatalError("Gap not detected") }
        if case .complete(let data) = receiver.accept(frame(Data(text.dropFirst(8)), offset: 8, total: text.count, crc: crc, flags: 3)) {
            check(data == text)
        } else { fatalError("Text reassembly failed") }
        let oversized = ReportAssembly(asset: 1, generation: 7)
        if case .failed = oversized.accept(frame(Data([1]), offset: 0, total: 2_000_000, crc: 0, flags: 0, asset: 1)) {} else { fatalError("Oversize accepted") }
        check(oversized.offset == 0)
        let corrupt = ReportAssembly(asset: 0, generation: 7)
        if case .failed = corrupt.accept(frame(text, offset: 0, total: text.count, crc: crc ^ 1, flags: 3)) {} else { fatalError("Bad CRC accepted") }
        let report = PhoneReport(id: id, kind: 3, endedAt: 1, text: "暂停了", truncated: false, images: [])
        let json = try! JSONEncoder().encode(report)
        check(PhoneReport.decode(json, expected: id)?.title == "异常暂停了")
        check(PhoneReport.decode(json, expected: id)?.audio == nil) // Old PC stays compatible.
        let firstMember = ReportMember(name: "同名任务", kind: 1, id: "0000000000000001")
        let secondMember = ReportMember(name: "同名任务", kind: 1, id: "0000000000000002")
        let renamedMember = ReportMember(name: "修改后的名称", kind: 1, id: firstMember.id)
        let colorMap = ThreadColorMap([firstMember, secondMember])
        check(colorMap.rgb(for: firstMember) != colorMap.rgb(for: secondMember))
        check(colorMap.rgb(for: firstMember) == ThreadColorMap([secondMember, firstMember]).rgb(for: firstMember))
        check(ThreadColorMap([firstMember]).rgb(for: firstMember) == ThreadColorMap([renamedMember]).rgb(for: renamedMember))
        let allColors = (0..<32).map { ReportMember(name: "任务", kind: 1, id: "bounded-\($0)") }
        let completeMap = ThreadColorMap(allColors)
        check(Set(allColors.map { completeMap.rgb(for: $0) }).count == 32)
        check(Set(ThreadColorMap.palette).count == 32)
        let firstText = "只读最终回复🙂。"
        let secondText = "The output is ready."
        var sectionReport = PhoneReport(id: id, kind: 1, endedAt: 1,
            text: firstText + "\n\n" + secondText, truncated: false, images: [],
            heading: "2 个任务已结束", members: [firstMember, secondMember], sections: [
                ReportSection(member: 0, offset: 0, length: firstText.utf8.count),
                ReportSection(member: 1, offset: firstText.utf8.count + 2, length: secondText.utf8.count)])
        let sectionData = try! JSONEncoder().encode(sectionReport)
        let decodedSections = PhoneReport.decode(sectionData, expected: id)!
        check(decodedSections.sections == sectionReport.sections)
        check(decodedSections.displaySections.count == 2 && decodedSections.displaySections[0].text == firstText)
        check(decodedSections.text == firstText + "\n\n" + secondText && !decodedSections.text.contains("同名任务"))
        sectionReport.text += "\n\n更多内容请在电脑查看。"
        check(sectionReport.displaySections.count == 3 && sectionReport.displaySections.last?.member == nil)
        check(sectionReport.displaySections.last?.text == "更多内容请在电脑查看。")
        let invalidSections = [
            [ReportSection(member: 2, offset: 0, length: 3)],
            [ReportSection(member: 0, offset: -1, length: 3)],
            [ReportSection(member: 0, offset: 0, length: 0)],
            [ReportSection(member: 0, offset: 1, length: 2)], // Starts inside a UTF-8 scalar.
            [ReportSection(member: 0, offset: 0, length: 1)], // Ends inside a UTF-8 scalar.
            [ReportSection(member: 0, offset: Int.max, length: Int.max)],
            [ReportSection(member: 0, offset: 0, length: 6), ReportSection(member: 1, offset: 3, length: 3)],
            Array(repeating: ReportSection(member: 0, offset: 0, length: 3), count: 33)
        ]
        for sections in invalidSections {
            sectionReport.sections = sections
            let decoded = PhoneReport.decode(try! JSONEncoder().encode(sectionReport), expected: id)
            check(decoded?.sections == nil && decoded?.text == sectionReport.text)
        }
        var malformedSections = try! JSONSerialization.jsonObject(with: sectionData) as! [String: Any]
        malformedSections["sections"] = "invalid optional metadata"
        var recovered = PhoneReport.decode(try! JSONSerialization.data(withJSONObject: malformedSections), expected: id)
        check(recovered?.sections == nil && recovered?.text == decodedSections.text)
        malformedSections["sections"] = [["member": 0, "offset": "wrong type", "length": 3]]
        recovered = PhoneReport.decode(try! JSONSerialization.data(withJSONObject: malformedSections), expected: id)
        check(recovered?.sections == nil && recovered?.text == decodedSections.text)
        let descriptor = ReportAudio(version: 1, segments: 512, codec: "mp3")
        check(descriptor.valid && !ReportAudio(version: 1, segments: 0, codec: "mp3").valid)
        check(!ReportAudio(version: 1, segments: 513, codec: "mp3").valid)
        check(!ReportAudio(version: 2, segments: 1, codec: "mp3").valid)
        check(!ReportAudio(version: 1, segments: 1, codec: "wav").valid)
        var audioReport = report; audioReport.audio = descriptor
        check(PhoneReport.decode(try! JSONEncoder().encode(audioReport), expected: id)?.audio == descriptor)
        audioReport.audio = ReportAudio(version: 2, segments: 1, codec: "unknown")
        let futureAudio = PhoneReport.decode(try! JSONEncoder().encode(audioReport), expected: id)
        check(futureAudio?.text == report.text && futureAudio?.audio == nil)
        check(PhoneReport.decode(json, expected: UUID()) == nil)
        let question = PhoneReport(id: id, kind: 4, endedAt: 1, text: "请选择答案", truncated: false, images: [])
        check(PhoneReport.decode(try! JSONEncoder().encode(question), expected: id)?.title == "请回答问题")
        var badImages = report
        badImages.images = [ReportImage(index: 1, name: "a"), ReportImage(index: 1, name: "b")]
        check(PhoneReport.decode(try! JSONEncoder().encode(badImages), expected: id) == nil)
        let start = ReportWire.request(id: id, asset: 253, offset: 1, generation: 9)
        let end = ReportWire.request(id: id, asset: 253, offset: 2, generation: 9)
        let release = ReportWire.request(id: id, asset: 253, offset: 3, generation: 9)
        check(start.count == 28 && start[3] == 253 && ReportWire.u32(start, 20) == 1)
        check(end.count == 28 && ReportWire.u32(end, 20) == 2 && start[4..<20] == end[4..<20])
        check(release.count == 28 && release[3] == 253 && ReportWire.u32(release, 20) == 3
              && start[4..<20] == release[4..<20])
        let member = ReportMember(name: "论文图表", kind: 1)
        var brief = ReportBrief(id: id, kind: 1, heading: "3 个任务已结束", taskCount: 3,
                                completedCount: 2, pausedCount: 1, members: [member], mode: "default")
        check(ReportBrief.decode(try! JSONEncoder().encode(brief), expected: id) == brief)
        check(ReportBrief.decode(try! JSONEncoder().encode(brief), expected: UUID()) == nil)
        var invalid = brief; invalid.pausedCount = 2
        check(ReportBrief.decode(try! JSONEncoder().encode(invalid), expected: id) == nil)
        invalid = brief; invalid.taskCount = 0
        check(ReportBrief.decode(try! JSONEncoder().encode(invalid), expected: id) == nil)
        check(ReportBrief.decode(Data(repeating: 32, count: 4097), expected: id) == nil)
        let briefBytes = try! JSONEncoder().encode(brief)
        let briefAssembly = ReportAssembly(asset: 254, generation: 7)
        if case .complete(let bytes) = briefAssembly.accept(frame(briefBytes, offset: 0, total: briefBytes.count,
                crc: ReportWire.crc32(briefBytes), flags: 3, asset: 254)) { check(bytes == briefBytes) }
        else { fatalError("Brief assembly failed") }
        let oversizedBrief = ReportAssembly(asset: 254, generation: 7)
        if case .failed = oversizedBrief.accept(frame(Data([1]), offset: 0, total: 4097, crc: 0, flags: 0, asset: 254)) {}
        else { fatalError("Oversized brief accepted") }
        var custom = PhoneReport(id: id, kind: 5, endedAt: 1, text: "开会提醒", truncated: false, images: [])
        custom.heading = "会议提醒"; custom.mode = "notification"
        check(PhoneReport.decode(try! JSONEncoder().encode(custom), expected: id)?.title == "会议提醒")
        check(custom.brief.completedCount == 0 && custom.brief.pausedCount == 0)
        var batch = CallReportBatch()
        check(batch.absorb(brief) && batch.rootID == id && batch.taskCount == 3)
        brief.taskCount = 4; brief.completedCount = 3
        check(batch.absorb(brief) && batch.taskCount == 4 && batch.items.count == 1)
        let second = ReportBrief.fallback(EventFrame(id: UUID(), kind: .abnormalPaused))
        check(batch.absorb(second) && batch.rootID == id && batch.taskCount == 5 && batch.pausedCount == 2)
        for _ in 0..<30 { check(batch.absorb(.fallback(EventFrame(id: UUID(), kind: .turnEnded)))) }
        let countBeforeRollover = batch.taskCount
        check(batch.items.count == 32 && batch.absorb(.fallback(EventFrame(id: UUID(), kind: .turnEnded))))
        check(batch.items.count == 32 && batch.taskCount == countBeforeRollover + 1 && batch.rootID == id)
        batch.reset(); check(batch.rootID == nil && batch.taskCount == 0)
        var speech = BoundedSpeechQueue()
        check(speech.enqueue(id: id, text: "报告一"))
        check(!speech.enqueue(id: id, text: "重复报告") && speech.count == 1)
        check(speech.pop()?.id == id && speech.isEmpty)
        check(!speech.enqueue(id: id, text: "已经播过的报告"))
        speech.reset()
        for _ in 0..<16 { check(speech.enqueue(id: UUID(), text: "短报告")) }
        check(!speech.enqueue(id: UUID(), text: "超出容量") && speech.count == 16)
        speech.reset()
        for _ in 0..<2 { check(speech.enqueue(id: UUID(), text: String(repeating: "中", count: 30000))) }
        check(speech.pendingBytes <= 128 * 1024 && speech.truncatedReports == 2)
        check(!speech.enqueue(id: UUID(), text: String(repeating: "中", count: 30000)))
        _ = speech.pop()
        check(speech.enqueue(id: UUID(), text: String(repeating: "中", count: 30000)))
        speech.reset(); check(speech.characterCount == 0 && speech.pendingBytes == 0 && speech.isEmpty)
        for _ in 0..<160 { check(speech.enqueue(id: UUID(), text: "继续汇报")); _ = speech.pop() }
        check(speech.pendingBytes == 0 && speech.characterCount == 0)
        var waiting = BodyWaitDeadline(at: 100)
        check(waiting.remaining(at: 124) == 1 && waiting.remaining(at: 125) == 0)
        waiting.progress(at: 124)
        check(waiting.remaining(at: 125) == 24 && waiting.remaining(at: 149) == 0)
        waiting.progress(at: 123) // An older callback cannot roll the progress clock back.
        check(waiting.remaining(at: 125) == 24)
        waiting.progress(at: 219)
        check(waiting.remaining(at: 219) == 1 && waiting.remaining(at: 220) == 0)
        waiting.progress(at: 300) // Progress never removes the absolute two-minute limit.
        check(waiting.remaining(at: 300) == 0)
        let logical = frame(text, offset: 0, total: text.count, crc: crc, flags: 3)
        func fragments(_ bytes: Data, generation: UInt32 = 7) -> [Data] {
            var output: [Data] = []
            for offset in stride(from: 0, to: bytes.count, by: 12) {
                var packet = Data([0x43, 0x46]); ReportWire.append(generation, to: &packet)
                let last = offset + 12 >= bytes.count
                let sequence = UInt16(offset / 12) | (last ? 0x8000 : 0)
                packet.append(UInt8(truncatingIfNeeded: sequence)); packet.append(UInt8(truncatingIfNeeded: sequence >> 8))
                packet.append(bytes[offset..<min(offset + 12, bytes.count)]); output.append(packet)
            }
            return output
        }
        let tiny = fragments(logical)
        check(tiny.allSatisfy { $0.count <= 20 })
        let smallMTU = ReportAssembly(asset: 0, generation: 7)
        for (index, packet) in tiny.enumerated() {
            if index == tiny.count - 1 {
                if case .complete(let result) = smallMTU.accept(packet) { check(result == text) }
                else { fatalError("20-byte CF reassembly failed") }
            } else if case .more = smallMTU.accept(packet) {} else { fatalError("CF sequence rejected") }
        }
        let wrongGeneration = ReportAssembly(asset: 0, generation: 7)
        if case .ignored = wrongGeneration.accept(fragments(logical, generation: 8)[0]) {} else { fatalError("Old CF generation accepted") }
        check(wrongGeneration.offset == 0)
        let gap = ReportAssembly(asset: 0, generation: 7)
        if case .retry = gap.accept(tiny[1]) {} else { fatalError("CF gap accepted") }
        for packet in tiny.dropFirst(2) {
            if case .ignored = gap.accept(packet) {} else { fatalError("CF tail exhausted retry budget") }
        }
        for (index, packet) in tiny.enumerated() {
            if index == tiny.count - 1 {
                if case .complete(let result) = gap.accept(packet) { check(result == text) }
                else { fatalError("CF did not recover after missing fragment") }
            } else if case .more = gap.accept(packet) {} else { fatalError("CF retry sequence rejected") }
        }
        let damagedWindow = ReportAssembly(asset: 0, generation: 7)
        var retryGate = ReportRetryGate()
        var scheduledRetries = 0
        func observeDamagedPacket(_ packet: Data) {
            if case .retry = damagedWindow.accept(packet), retryGate.schedule() { scheduledRetries += 1 }
        }
        observeDamagedPacket(tiny[1]) // First logical frame lost its initial fragment.
        for offset in [text.count, text.count * 2] {
            let later = frame(text, offset: offset, total: text.count * 3, crc: 42, flags: 0)
            for packet in fragments(later) { observeDamagedPacket(packet) }
        }
        check(scheduledRetries == 1 && retryGate.pending && !retryGate.allowsWindow)
        retryGate.release()
        check(retryGate.allowsWindow && !retryGate.schedule()) // Still coalesced until write.
        retryGate.sent()
        check(!retryGate.pending && retryGate.schedule()) // A genuinely new failed window may retry.
        let overflow = ReportAssembly(asset: 0, generation: 7)
        var huge = Data([0x43, 0x46]); ReportWire.append(7, to: &huge); huge.append(contentsOf: [0, 128]); huge.append(Data(repeating: 0, count: 513))
        if case .failed = overflow.accept(huge) {} else { fatalError("CF overflow accepted") }
        let audioBytes = Data([0x49, 0x44, 0x33, 1, 2, 3])
        let audioCRC = ReportWire.crc32(audioBytes)
        for asset in [UInt8(16), UInt8(17)] {
            let audioAssembly = ReportAssembly(asset: asset, generation: 7)
            let audioFrame = frame(audioBytes, offset: 0, total: audioBytes.count, crc: audioCRC, flags: 3, asset: asset)
            if case .complete(let result) = audioAssembly.accept(audioFrame) { check(result == audioBytes) }
            else { fatalError("Audio envelope rejected") }
            let staleAudio = ReportAssembly(asset: asset, generation: 8)
            if case .ignored = staleAudio.accept(audioFrame) {} else { fatalError("Audio old generation accepted") }
            check(staleAudio.offset == 0)
            let boundedAudio = ReportAssembly(asset: asset, generation: 7)
            if case .failed = boundedAudio.accept(frame(Data([1]), offset: 0, total: ReportAudio.maximumBytes + 1,
                                                        crc: 0, flags: 0, asset: asset)) {} else { fatalError("Oversize audio accepted") }
            check(boundedAudio.offset == 0)
            let fragmentedAudio = ReportAssembly(asset: asset, generation: 7)
            let pieces = fragments(audioFrame)
            for (index, packet) in pieces.enumerated() {
                if index == pieces.count - 1 {
                    if case .complete(let result) = fragmentedAudio.accept(packet) { check(result == audioBytes) }
                    else { fatalError("Fragmented audio rejected") }
                } else if case .more = fragmentedAudio.accept(packet) {} else { fatalError("Audio fragment order rejected") }
            }
        }
        print("PASS: \(checks) report assertions; CRC, bounds, UTF-8, stale/duplicate/gap, kind and manifest validation.")
    }
}
