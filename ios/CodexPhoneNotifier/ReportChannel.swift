import Foundation
import CoreBluetooth

/// One in-flight resource, credit-window reads, no idle timers or image files.
final class ReportChannel {
    static let dataUUID = CBUUID(string: "5e2f4d60-a84c-4db0-89ed-95a76e5ac904")
    static let requestUUID = CBUUID(string: "5e2f4d60-a84c-4db0-89ed-95a76e5ac905")
    var completed: ((UUID, UInt8, Data) -> Void)?
    var failed: ((UUID, String) -> Void)?
    var sessionCompleted: ((UUID, UInt32, Bool) -> Void)?
    var bodyProgress: ((UUID, Int) -> Void)?
    private weak var peripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?
    private var requestCharacteristic: CBCharacteristic?
    private var id: UUID?
    private var assembly: ReportAssembly?
    private var audioRequest: AudioSegmentRequest?
    private var generation = UInt32.random(in: 1...UInt32.max)
    private var deadline: DispatchWorkItem?
    private var bodyLimit: DispatchWorkItem?
    private var deadlineAt: TimeInterval?
    private var retries = 0
    private var retryGate = ReportRetryGate()
    private var writeInFlight = false
    private var wantsWindow = false
    private var cancellation: Data?
    private struct SessionCommand {
        let id: UUID
        let action: UInt32
        var retries = 0
    }
    private var sessionCommands: [SessionCommand] = []
    private var deferredEnds: [SessionCommand] = []
    private var inFlightSession: SessionCommand?
    private var controlRetry: DispatchWorkItem?
    var available: Bool { dataCharacteristic != nil && requestCharacteristic != nil }
    var receivingBody: Bool { assembly?.asset == 0 }
    var receivingBrief: Bool { assembly?.asset == 254 }
    var busy: Bool { assembly != nil }
    var activeAsset: UInt8? { assembly?.asset }

    func session(_ id: UUID, active: Bool, provisional: Bool = false) {
        let action: UInt32 = active ? 1 : (provisional ? 3 : 2)
        sessionCommands.removeAll { $0.id == id }
        deferredEnds.removeAll { $0.id == id }
        if sessionCommands.count >= 8 {
            guard let oldEnd = sessionCommands.firstIndex(where: { $0.action != 1 }) else {
                sessionCompleted?(id, action, false); return
            }
            sessionCommands.remove(at: oldEnd)
        }
        sessionCommands.append(SessionCommand(id: id, action: action))
        pump()
    }

    func attach(_ target: CBPeripheral, characteristics: [CBCharacteristic]) {
        peripheral = target
        dataCharacteristic = characteristics.first { $0.uuid == Self.dataUUID }
        requestCharacteristic = characteristics.first { $0.uuid == Self.requestUUID }
        for command in deferredEnds where !sessionCommands.contains(where: { $0.id == command.id }) {
            if sessionCommands.count < 8 { sessionCommands.append(command) }
        }
        deferredEnds.removeAll()
        if let data = dataCharacteristic, !data.isNotifying { target.setNotifyValue(true, for: data) }
    }
    func reset() {
        cancel(notifyPeer: false)
        controlRetry?.cancel(); controlRetry = nil
        let pending = (inFlightSession.map { [$0] } ?? []) + sessionCommands
        for command in pending where command.action != 1 {
            deferredEnds.removeAll { $0.id == command.id }
            deferredEnds.append(SessionCommand(id: command.id, action: command.action))
        }
        deferredEnds = Array(deferredEnds.suffix(8))
        sessionCommands.removeAll(); inFlightSession = nil
        peripheral = nil; dataCharacteristic = nil; requestCharacteristic = nil
        writeInFlight = false
    }
    func cancel(notifyPeer: Bool = true) {
        if notifyPeer, let id {
            cancellation = ReportWire.request(id: id, asset: 255, offset: 0, generation: generation)
        } else { cancellation = nil }
        generation &+= 1
        deadline?.cancel(); deadline = nil
        bodyLimit?.cancel(); bodyLimit = nil; deadlineAt = nil
        retryGate.sent()
        assembly = nil; audioRequest = nil; id = nil; wantsWindow = false
        if notifyPeer { pump() }
    }
    func fetch(_ id: UUID, asset: UInt8 = 0) {
        beginFetch(id, asset: asset, audio: nil)
    }
    func fetchAudio(_ request: AudioSegmentRequest) {
        guard request.valid else { return }
        beginFetch(request.id, asset: request.asset, audio: request)
    }
    private func beginFetch(_ id: UUID, asset: UInt8, audio: AudioSegmentRequest?) {
        cancel(notifyPeer: false)
        self.id = id
        audioRequest = audio
        retries = 0
        assembly = ReportAssembly(asset: asset, generation: generation)
        if asset == 0 || audio != nil {
            if asset == 0 { bodyProgress?(id, 0) }
            let ticket = generation
            let limit = DispatchWorkItem { [weak self] in
                guard let self, self.generation == ticket, self.id == id, self.assembly?.asset == asset else { return }
                self.finishFailure(audio == nil ? "本次正文接收超过两分钟，请查看电脑。" : "自然语音准备超时。")
            }
            bodyLimit = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + (audio == nil ? 120 : 90), execute: limit)
        }
        wantsWindow = true
        pump()
        armDeadline()
    }
    func subscribed(_ error: Error?) {
        if error != nil { finishFailure("安全传输通道尚未就绪，请重新连接电脑。"); return }
        pump()
    }
    func wrote(_ error: Error?) {
        writeInFlight = false
        if var command = inFlightSession {
            inFlightSession = nil
            if error != nil {
                let superseded = sessionCommands.contains { $0.id == command.id }
                if !superseded && command.retries < 2 {
                    command.retries += 1
                    sessionCommands.insert(command, at: 0)
                    let task = DispatchWorkItem { [weak self] in self?.controlRetry = nil; self?.pump() }
                    controlRetry = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
                    return
                }
                if !superseded {
                    if command.action != 1 {
                        deferredEnds.removeAll { $0.id == command.id }
                        deferredEnds.append(SessionCommand(id: command.id, action: command.action))
                        deferredEnds = Array(deferredEnds.suffix(8))
                    }
                    sessionCompleted?(command.id, command.action, false)
                }
            } else { sessionCompleted?(command.id, command.action, true) }
            pump(); return
        }
        if error != nil {
            // An in-flight server window may finish just after its last packet.
            // A single short retry avoids busy writes and preserves the current offset.
            retry(after: 0.35)
        } else { pump() }
    }
    private func pump() {
        guard controlRetry == nil else { return }
        if !sessionCommands.isEmpty, !writeInFlight, let target = peripheral,
           target.state == .connected, let command = requestCharacteristic {
            let intent = sessionCommands.removeFirst()
            let value = ReportWire.request(id: intent.id, asset: 253, offset: Int(intent.action), generation: generation)
            guard target.maximumWriteValueLength(for: .withResponse) >= value.count else {
                sessionCompleted?(intent.id, intent.action, false); return
            }
            writeInFlight = true; inFlightSession = intent
            target.writeValue(value, for: command, type: .withResponse)
            return
        }
        if let cancellation, !writeInFlight, let target = peripheral,
           target.state == .connected, let command = requestCharacteristic {
            self.cancellation = nil; writeInFlight = true
            target.writeValue(cancellation, for: command, type: .withResponse)
            return
        }
        guard wantsWindow, retryGate.allowsWindow, !writeInFlight, let id, let assembly,
              let target = peripheral, target.state == .connected,
              let command = requestCharacteristic, dataCharacteristic?.isNotifying == true else { return }
        let data = audioRequest.map { ReportWire.audioRequest($0, offset: assembly.offset, generation: generation) }
            ?? ReportWire.request(id: id, asset: assembly.asset, offset: assembly.offset, generation: generation)
        guard target.maximumWriteValueLength(for: .withResponse) >= data.count else {
            finishFailure("蓝牙连接的包长度不足，请重新连接。"); return
        }
        wantsWindow = false; writeInFlight = true; retryGate.sent()
        target.writeValue(data, for: command, type: .withResponse)
    }
    func receive(_ data: Data) {
        guard let id, let value = assembly else { return }
        let previousOffset = value.offset
        let result = value.accept(data)
        if value.asset == 0, value.offset > previousOffset { bodyProgress?(id, value.offset) }
        switch result {
        case .ignored: return
        case .more: armDeadline()
        case .nextWindow:
            guard !retryGate.pending else { return }
            retries = 0; wantsWindow = true; armDeadline(); pump()
        case .retry: retry(after: 0.15)
        case .failed:
            finishFailure(audioRequest != nil ? "本段自然语音暂不可用。"
                : (value.asset == 0 ? "本次正文暂不可用，请查看电脑。" : "图片暂不可用或已更新，请查看电脑原图。"))
        case .complete(let payload):
            deadline?.cancel(); deadline = nil; assembly = nil; wantsWindow = false
            bodyLimit?.cancel(); bodyLimit = nil; deadlineAt = nil
            retryGate.sent()
            audioRequest = nil
            completed?(id, value.asset, payload)
        }
    }
    private func armDeadline() {
        guard retryGate.allowsWindow else { return }
        let delay: TimeInterval = audioRequest != nil && assembly?.offset == 0 ? 35
            : (assembly?.asset == 254 ? 1.5 : 18)
        deadlineAt = ProcessInfo.processInfo.systemUptime + delay
        guard deadline == nil else { return }
        scheduleDeadline(after: delay)
    }
    private func scheduleDeadline(after delay: TimeInterval) {
        let ticket = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket, self.assembly != nil else { return }
            self.deadline = nil
            let remaining = (self.deadlineAt ?? 0) - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { self.scheduleDeadline(after: remaining); return }
            if self.retryGate.pending {
                self.finishFailure("传输请求未能发出，请重新连接电脑。"); return
            }
            self.retry(after: 0)
        }
        deadline = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func retry(after delay: Double) {
        guard assembly != nil, retryGate.schedule() else { return }
        retries += 1
        if retries > (assembly?.asset == 254 ? 0 : 2) { finishFailure("传输未完成，请确认蓝牙配对后重试。"); return }
        deadline?.cancel()
        let ticket = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket, self.assembly != nil else { return }
            self.deadline = nil
            self.retryGate.release()
            // A pending withResponse write still owns its callback; never overlap it.
            self.wantsWindow = true
            self.pump(); self.armDeadline()
        }
        deadline = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func finishFailure(_ message: String) {
        guard let id else { return }
        cancel()
        failed?(id, message)
    }
}
