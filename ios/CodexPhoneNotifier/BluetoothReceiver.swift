import Foundation
import Combine
import CoreBluetooth
import UserNotifications
import UIKit
import WidgetKit
import ImageIO

struct ComputerChoice: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
}

/// UI and BLE mutations run on the main queue. Notification callbacks hop back to it.
final class BluetoothReceiver: NSObject, ObservableObject {
    static let shared = BluetoothReceiver()
    static let serviceUUID = CBUUID(string: "5e2f4d60-a84c-4db0-89ed-95a76e5ac901")
    private static let eventUUID = CBUUID(string: "5e2f4d60-a84c-4db0-89ed-95a76e5ac902")
    private static let ackUUID = CBUUID(string: "5e2f4d60-a84c-4db0-89ed-95a76e5ac903")

    @Published private(set) var connectionText = "正在检查蓝牙"
    @Published private(set) var notificationText = "正在检查通知权限"
    @Published private(set) var notificationDiagnostics = ""
    @Published private(set) var notificationNeedsSettings = false
    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var listeningEnabled: Bool
    @Published private(set) var selectedName: String
    @Published private(set) var selectedID: UUID?
    @Published private(set) var computers: [ComputerChoice] = []
    @Published private(set) var history: [EventRecord]
    @Published private(set) var lastError: String?
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var controlStateText = "正在检查控制中心"
    @Published private(set) var accessorySetupText = "正在检查电脑授权"
    @Published private(set) var accessorySetupReady = false
    @Published private(set) var accessoryNeedsAuthorization = false
    @Published private(set) var accessoryPickerActive = false

    private let defaults = UserDefaults.standard
    private let notifications = UNUserNotificationCenter.current()
    private var central: CBCentralManager?
    // Type-erased storage preserves the pre-iOS 18 CoreBluetooth path.
    private var accessoryCoordinator: AnyObject?
    private var accessoryPickerCommand: UInt64?

    var usesAccessorySetup: Bool {
        if #available(iOS 18.0, *) { return !Self.isDesignPreview && !Self.isControlUITest }
        return false
    }

    @available(iOS 18.0, *)
    private var accessories: AccessorySetupCoordinator? { accessoryCoordinator as? AccessorySetupCoordinator }
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private var restoredToCancel: [CBPeripheral] = []
    private var deliveredIDs: [String]
    private var processingIDs: Set<UUID> = []
    private var newestEventID: UUID?
    private var ackQueue: [Data] = []
    private var ackInFlight: Data?
    private var recovery = BluetoothRecovery()
    private var connectionDiagnostics = BluetoothDiagnostics(data: UserDefaults.standard.data(forKey: "bluetoothDiagnostics"))
    private var connectionFailureCode: Int?
    private var preparationInProgress = false
    // Invalidate outstanding permission/add callbacks when the user stops or changes computer.
    private var sessionGeneration = 0
    private var controlCommands = ControlCommandGate()

    enum AlertMode: String, CaseIterable { case notification, call
        var label: String { self == .call ? "来电汇报" : "普通通知" }
    }
    @Published var alertMode = AlertMode(rawValue: UserDefaults.standard.string(forKey: "alertMode") ?? "") ?? .notification {
        didSet { defaults.set(alertMode.rawValue, forKey: "alertMode"); if alertMode == .notification { VoiceReporter.shared.end() } }
    }
    @Published private(set) var latestReport: PhoneReport? = {
        guard let data = UserDefaults.standard.data(forKey: "latestReport"), data.count <= 96 * 1024 else { return nil }
        return try? JSONDecoder().decode(PhoneReport.self, from: data)
    }()
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var reportStatus = ""
    @Published var showReport = false
    private let reportChannel = ReportChannel()
    private var imagesAcceptedFor: UUID?
    private var imageAsset: Int?
    private var imageRevision = 0
    private var memoryObserver: NSObjectProtocol?
    private var reportVisible = false
    private var resumeReportWhenConnected = false
    private var reportQueue: [EventFrame] = []
    private var currentFrame: EventFrame?
    private var currentBrief: ReportBrief?
    private var fetchingBrief = false
    private var callRootID: UUID?
    private var reservedCallRootID: UUID?
    private var pendingPermissionFrames: [UUID: EventFrame] = [:]
    private var callMembers: Set<UUID> = []
    private var failedCallBatch = false
    private var deferredImage: Int?
    private var pendingAudio = BoundedAudioRequests()
    private var currentAudioRequest: AudioSegmentRequest?
    private var bodyAfterAudio = false

    private func setupReports() {
        VoiceReporter.shared.audioRequested = { [weak self] request in
            guard let self, self.listeningEnabled, self.reportChannel.available,
                  self.pendingAudio.append(request) else {
                VoiceReporter.shared.receiveAudio(request, data: nil); return
            }
            self.pumpReports()
        }
        VoiceReporter.shared.audioCancelled = { [weak self] token in
            guard let self else { return }
            self.pendingAudio.remove(token: token)
            if self.currentAudioRequest?.token == token {
                self.currentAudioRequest = nil; self.reportChannel.cancel()
            }
            DispatchQueue.main.async { [weak self] in self?.pumpReports() }
        }
        VoiceReporter.shared.voiceUnavailable = { [weak self] message in self?.reportStatus = message }
        reportChannel.bodyProgress = { [weak self] id, offset in
            guard let self, self.listeningEnabled, self.currentFrame?.id == id, !self.fetchingBrief else { return }
            VoiceReporter.shared.bodyProgress(id: id, offset: offset)
        }
        reportChannel.sessionCompleted = { [weak self] id, action, success in
            guard let self, action == 1, self.callRootID == id else { return }
            if success { self.reservedCallRootID = id; return }
            self.reservedCallRootID = nil; self.failedCallBatch = true
            self.reportStatus = "电脑未确认保留本次汇报，已停止来电方式。"
            if VoiceReporter.shared.hasCallSession { VoiceReporter.shared.end() }
            else {
                self.reportChannel.session(id, active: false, provisional: true)
                self.callRootID = nil
            }
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                              object: nil, queue: .main) { [weak self] _ in self?.releasePreview() }
        let listen = UNNotificationAction(identifier: "codex.listen", title: "听汇报", options: [.foreground])
        notifications.setNotificationCategories([UNNotificationCategory(identifier: "codex.report", actions: [listen],
                                                                       intentIdentifiers: [], options: [])])
        if !defaults.bool(forKey: "latestReportMigration") {
            notifications.removeAllDeliveredNotifications()
            defaults.set(true, forKey: "latestReportMigration")
            if let saved = try? JSONEncoder().encode(history) { defaults.set(saved, forKey: "eventHistory") }
        }
        reportChannel.completed = { [weak self] id, asset, data in
            guard let self, self.listeningEnabled else { return }
            if asset == 16 || asset == 17 {
                guard let request = self.currentAudioRequest, request.id == id, request.asset == asset else { return }
                self.currentAudioRequest = nil; self.bodyAfterAudio = true
                VoiceReporter.shared.receiveAudio(request, data: data)
                self.pumpReports()
            } else if asset == 254 {
                guard self.currentFrame?.id == id, self.fetchingBrief else { return }
                let decoded = ReportBrief.decode(data, expected: id)
                let brief = decoded?.kind == self.currentFrame?.kind.rawValue ? decoded : nil
                self.finishBrief(brief)
            } else if asset == 0 {
                guard let report = PhoneReport.decode(data, expected: id) else {
                    self.reportFailed(id, message: "正文格式无效，请查看电脑。"); return
                }
                guard self.currentFrame?.id == id || self.latestReport?.id == id else { return }
                if let frame = self.currentFrame, frame.id == id, report.kind != frame.kind.rawValue {
                    self.reportFailed(id, message: "正文类型不一致，请查看电脑。"); return
                }
                if self.latestReport?.id == id { self.latestReport = report; self.persistReport(); self.reportStatus = "" }
                if VoiceReporter.shared.contains(id) { _ = VoiceReporter.shared.absorb(report.brief) }
                VoiceReporter.shared.supply(id: id, text: report.text, audio: report.audio)
                self.finishBody(id)
            } else {
                guard self.latestReport?.id == id, self.imagesAcceptedFor == id, self.imageAsset == Int(asset) else { return }
                self.imageAsset = nil
                let revision = self.imageRevision
                DispatchQueue.global(qos: .userInitiated).async {
                    let options = [kCGImageSourceShouldCache: false] as CFDictionary
                    var thumbnail: UIImage?
                    if data.count <= 512 * 1024,
                       let source = CGImageSourceCreateWithData(data as CFData, options),
                       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? Int,
                       let height = properties[kCGImagePropertyPixelHeight] as? Int,
                       width > 0, height > 0, width <= 1280, height <= 1280,
                       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1280
                       ] as CFDictionary) {
                        thumbnail = UIImage(cgImage: image)
                    }
                    DispatchQueue.main.async {
                        guard self.latestReport?.id == id, self.imageRevision == revision else { return }
                        self.previewImage = thumbnail
                        self.reportStatus = thumbnail == nil ? "图片无法显示" : ""
                    }
                }
            }
        }
        reportChannel.failed = { [weak self] id, message in
            guard let self else { return }
            if let request = self.currentAudioRequest, request.id == id {
                self.currentAudioRequest = nil; self.bodyAfterAudio = true
                VoiceReporter.shared.receiveAudio(request, data: nil)
                self.pumpReports()
            } else { self.reportFailed(id, message: message) }
        }
        VoiceReporter.shared.accepted = { [weak self] id in
            guard let self, let latest = self.latestReport,
                  latest.id == id || VoiceReporter.shared.contains(latest.id) else { return }
            self.imagesAcceptedFor = latest.id
            if let first = self.latestReport?.images.first { self.loadImage(first.index) }
        }
        VoiceReporter.shared.ended = { [weak self] id in
            guard let self else { return }
            if self.callRootID == id { self.endCallSession() }
            if !self.reportVisible { self.releasePreview() }
        }
        VoiceReporter.shared.omitted = { [weak self] in
            self?.reportStatus = "汇报较多，部分内容未播报；完整内容请在手机或电脑查看。"
        }
    }
    private func endCallSession() {
        if let id = callRootID { reportChannel.session(id, active: false) }
        callRootID = nil; reservedCallRootID = nil
        let abandonedIDs = callMembers
        let abandoned = reportQueue.filter { abandonedIDs.contains($0.id) }
            + (currentFrame.flatMap { abandonedIDs.contains($0.id) ? [$0] : nil } ?? [])
            + pendingPermissionFrames.values.filter { abandonedIDs.contains($0.id) }
        for frame in abandoned {
            if !deliveredIDs.contains(frame.id.uuidString) { rememberDelivered(frame); enqueueAck(frame.data) }
            processingIDs.remove(frame.id)
            pendingPermissionFrames.removeValue(forKey: frame.id)
        }
        reportQueue.removeAll { abandonedIDs.contains($0.id) }
        if let frame = currentFrame, abandonedIDs.contains(frame.id) {
            reportChannel.cancel(); currentFrame = nil; currentBrief = nil; fetchingBrief = false
        }
        callMembers.removeAll()
        if !reportVisible { releasePreview() }
        pumpReports()
    }
    private func pumpReports() {
        guard listeningEnabled, currentFrame == nil, currentAudioRequest == nil else { return }
        if !pendingAudio.isEmpty && (!bodyAfterAudio || reportQueue.isEmpty) {
            if let index = imageAsset {
                deferredImage = index; reportChannel.cancel(); imageAsset = nil; imageRevision += 1
            }
            guard let request = pendingAudio.pop() else { return }
            guard reportChannel.available else {
                VoiceReporter.shared.receiveAudio(request, data: nil); pumpReports(); return
            }
            currentAudioRequest = request; bodyAfterAudio = true
            reportChannel.fetchAudio(request)
            return
        }
        guard !reportQueue.isEmpty else {
            if let index = deferredImage { deferredImage = nil; loadImage(index) }
            return
        }
        bodyAfterAudio = false
        if imageAsset != nil { reportChannel.cancel(); imageAsset = nil; imageRevision += 1 }
        let frame = reportQueue.removeFirst()
        currentFrame = frame; currentBrief = .fallback(frame); fetchingBrief = true
        let mayCall = !failedCallBatch && (alertMode == .call || VoiceReporter.shared.hasCallSession || frame.kind == .custom)
        if mayCall && callRootID == nil {
            callRootID = frame.id
            reservedCallRootID = nil
            reportChannel.session(frame.id, active: true) // Reserve before brief/full reads.
        }
        if reportChannel.available { reportChannel.fetch(frame.id, asset: 254) }
        else { finishBrief(nil) }
    }
    private func finishBrief(_ value: ReportBrief?) {
        guard let frame = currentFrame, fetchingBrief else { return }
        fetchingBrief = false
        let brief = value ?? .fallback(frame)
        currentBrief = brief
        if latestReport?.id == frame.id { latestReport?.apply(brief); persistReport() }
        let mode = frame.kind == .custom ? brief.mode : nil
        var wantsCall = frame.kind != .question && !failedCallBatch
            && (mode == "call" || (mode != "notification" && (alertMode == .call || VoiceReporter.shared.hasCallSession)))
        if wantsCall && reservedCallRootID != callRootID {
            wantsCall = false; failedCallBatch = true
        }
        let generation = sessionGeneration
        if wantsCall {
            if callRootID == nil { callRootID = frame.id; reportChannel.session(frame.id, active: true) }
            callMembers.insert(frame.id)
            defaults.set(frame.id.uuidString, forKey: "lastCallAttempt")
            VoiceReporter.shared.present(id: frame.id, brief: brief) { [weak self] accepted in
                guard let self, self.sessionGeneration == generation, self.currentFrame?.id == frame.id else { return }
                if accepted { self.finishDelivery(frame); self.fetchBody(frame) }
                else {
                    self.failedCallBatch = true
                    self.callMembers.remove(frame.id)
                    if let root = self.callRootID { self.reportChannel.session(root, active: false, provisional: true) }
                    self.callRootID = nil
                    self.reservedCallRootID = nil
                    self.reportStatus = "系统未能建立来电，已改用普通提醒。"
                    self.postNotification(frame, generation: generation) { [weak self] in self?.fetchBody(frame) }
                }
            }
        } else {
            callMembers.remove(frame.id)
            VoiceReporter.shared.discardExpectation(frame.id, finishIfIdle: false)
            if !VoiceReporter.shared.hasCallSession, let root = callRootID {
                reportChannel.session(root, active: false, provisional: true); callRootID = nil; reservedCallRootID = nil
            }
            postNotification(frame, generation: generation) { [weak self] in self?.fetchBody(frame) }
        }
    }
    private func fetchBody(_ frame: EventFrame) {
        guard currentFrame?.id == frame.id, listeningEnabled else { return }
        if reportChannel.available { reportChannel.fetch(frame.id) }
        else { reportFailed(frame.id, message: "电脑端暂不支持正文传输。") }
    }
    private func reportFailed(_ id: UUID, message: String) {
        if currentFrame?.id == id && fetchingBrief { finishBrief(nil); return }
        guard currentFrame?.id == id || latestReport?.id == id else { return }
        if imageAsset != nil { imageAsset = nil; reportStatus = message; return }
        let fallback = "完整汇报暂未收到，请查看电脑。"
        if latestReport?.id == id { reportStatus = message; latestReport?.replaceBodyWithFailure(fallback); persistReport() }
        VoiceReporter.shared.supply(id: id, text: fallback)
        finishBody(id)
    }
    private func finishBody(_ id: UUID) {
        callMembers.remove(id)
        VoiceReporter.shared.discardExpectation(id)
        if currentFrame?.id == id { currentFrame = nil; currentBrief = nil; fetchingBrief = false }
        if VoiceReporter.shared.isAccepted, let latest = latestReport, VoiceReporter.shared.contains(latest.id) {
            imagesAcceptedFor = latest.id
            if let first = latest.images.first { deferredImage = first.index }
        }
        pumpReports()
    }
    private func persistReport() {
        if let report = latestReport, let data = try? JSONEncoder().encode(report), data.count <= 96 * 1024 {
            defaults.set(data, forKey: "latestReport")
        } else { defaults.removeObject(forKey: "latestReport") }
    }
    private func beginReport(_ frame: EventFrame, fetch: Bool = true) {
        guard latestReport?.id != frame.id else { return }
        if imageAsset != nil { reportChannel.cancel() }
        imageRevision += 1; previewImage = nil; imageAsset = nil; imagesAcceptedFor = nil; deferredImage = nil
        notifications.removeAllDeliveredNotifications()
        latestReport = .placeholder(frame)
        resumeReportWhenConnected = false
        reportStatus = frame.kind == .question ? "" : (reportChannel.available ? "正在接收汇报" : "更新电脑端后可接收正文和图片")
        if frame.kind == .question { latestReport?.text = frame.kind.message }
        if fetch && frame.kind != .question { reportQueue.append(frame); pumpReports() }
        persistReport()
    }
    func listenToLatest() {
        guard let report = latestReport else { return }
        showReport = true
        VoiceReporter.shared.listen(id: report.id, text: report.text, brief: report.brief, audio: report.audio)
    }
    func previewVoice() {
        guard !VoiceReporter.shared.hasCallSession else {
            reportStatus = "请先结束当前汇报，再试听声音。"; return
        }
        guard reportChannel.available, let report = latestReport, report.audio?.valid == true else {
            reportStatus = "请连接已配置离线声库的电脑，收到一份新汇报后即可试听。"; return
        }
        VoiceReporter.shared.listen(id: report.id, text: report.text, brief: report.brief, audio: report.audio, preview: true)
    }
    func retryReport() {
        guard let report = latestReport, reportChannel.available else { return }
        guard currentFrame == nil, currentAudioRequest == nil, pendingAudio.isEmpty else { reportStatus = "正在按顺序接收汇报"; return }
        guard let kind = EventFrame.Kind(rawValue: report.kind) else { return }
        currentFrame = EventFrame(id: report.id, kind: kind); currentBrief = report.brief; fetchingBrief = false
        reportStatus = "正在接收汇报"
        reportChannel.fetch(report.id)
    }
    func loadImage(_ index: Int) {
        guard let report = latestReport, report.images.contains(where: { $0.index == index }),
              reportChannel.available else { return }
        imagesAcceptedFor = report.id
        if currentFrame != nil || !reportQueue.isEmpty || currentAudioRequest != nil || !pendingAudio.isEmpty {
            deferredImage = index; return
        }
        imageAsset = index
        imageRevision += 1; previewImage = nil
        reportStatus = "正在接收图片"
        reportChannel.fetch(report.id, asset: UInt8(index))
    }
    func releasePreview() {
        imageRevision += 1; previewImage = nil
        imagesAcceptedFor = nil; deferredImage = nil
        if imageAsset != nil { reportChannel.cancel(); imageAsset = nil }
    }
    func reportVisibilityChanged(_ visible: Bool) {
        reportVisible = visible
        if !visible { releasePreview() }
    }
    func clearLatestReport() {
        VoiceReporter.shared.end(); reportChannel.cancel()
        currentAudioRequest = nil; pendingAudio.reset()
        if callRootID != nil { endCallSession() }
        reportQueue.removeAll(); currentFrame = nil; currentBrief = nil; fetchingBrief = false
        callMembers.removeAll(); deferredImage = nil; pendingPermissionFrames.removeAll()
        imageRevision += 1; previewImage = nil; latestReport = nil; history = []
        imagesAcceptedFor = nil; imageAsset = nil; reportStatus = ""
        defaults.removeObject(forKey: "latestReport"); defaults.removeObject(forKey: "eventHistory")
        notifications.removeAllDeliveredNotifications()
    }
    func testIncomingCall() {
        guard !VoiceReporter.shared.hasCallSession, currentAudioRequest == nil, pendingAudio.isEmpty else {
            reportStatus = "请先结束当前汇报。"; return
        }
        let frame = EventFrame(id: UUID(), kind: .test)
        beginReport(frame, fetch: false)
        latestReport?.text = "这是 Codex 的来电汇报试听。接听后，任务的最终回复会在这里为你播报。"
        reportChannel.cancel(); reportStatus = ""; persistReport()
        VoiceReporter.shared.present(id: frame.id) { [weak self] success in
            guard let self else { return }
            if success { VoiceReporter.shared.supply(id: frame.id, text: self.latestReport?.text ?? "") }
            else { self.reportStatus = "系统未能建立来电，可点“听汇报”试听。" }
        }
    }


    static var isDesignPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ["home", "report", "settings"].contains(ProcessInfo.processInfo.environment["CODEX_DESIGN_PREVIEW"] ?? "")
        #else
        return false
        #endif
    }

    static var isControlUITest: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["CODEX_CONTROL_UI_TEST"] == "1"
            || UserDefaults.standard.bool(forKey: "codexControlUITest")
        #else
        return false
        #endif
    }

    private override init() {
        #if DEBUG && targetEnvironment(simulator)
        if Self.isControlUITest {
            listeningEnabled = UserDefaults.standard.bool(forKey: "listeningEnabled")
            selectedName = "模拟测试电脑"
            selectedID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")
            deliveredIDs = []
            history = []
            super.init()
            UserDefaults.standard.set(true, forKey: "codexControlUITest")
            notificationsAllowed = true
            notificationText = "模拟器控制测试"
            accessorySetupReady = true
            accessorySetupText = "已获系统配件授权"
            isConnected = listeningEnabled
            connectionText = listeningEnabled ? "模拟连接" : "提醒已暂停"
            _ = publishControlState()
            return // Real WidgetKit/Intents/shared storage; simulated BLE, isolated simulator only.
        }
        if Self.isDesignPreview {
            listeningEnabled = true
            selectedName = "我的电脑"
            selectedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")
            deliveredIDs = []
            history = [EventRecord(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                                   kind: .turnEnded, receivedAt: Date(), delivery: .scheduled)]
            super.init()
            isConnected = true
            connectionText = "已连接 · 等待 Codex 提醒"
            notificationsAllowed = true
            notificationText = "通知已开启"
            accessorySetupReady = true
            accessorySetupText = "已获系统配件授权"
            notificationDiagnostics = "横幅：开启 · 锁屏：开启 · 声音：开启 · 摘要：关闭"
            let parts = ["图表已整理完成，图片可以按需查看。",
                         "蓝牙提醒优化已通过验证，后台保持低资源占用。",
                         "资料核对暂时停止，请回到电脑查看原因。"]
            var sectionOffset = 0
            let sections = parts.enumerated().map { index, part in
                defer { sectionOffset += part.utf8.count + 2 }
                return ReportSection(member: index, offset: sectionOffset, length: part.utf8.count)
            }
            latestReport = PhoneReport(id: history[0].id, kind: 1, endedAt: Date().timeIntervalSince1970,
                                      text: parts.joined(separator: "\n\n"),
                                      truncated: false, images: [ReportImage(index: 1, name: "设计预览.jpg")],
                                      heading: "2 个完成 · 1 个暂停", taskCount: 3, completedCount: 2, pausedCount: 1,
                                      members: [ReportMember(name: "论文图表整理", kind: 1, id: "0000000000000001"),
                                                ReportMember(name: "蓝牙提醒优化", kind: 1, id: "0000000000000002"),
                                                ReportMember(name: "参考资料核对", kind: 3, id: "0000000000000003")], mode: "default", sections: sections)
            previewImage = UIImage(named: "CodexMark")
            return // Simulator fixture: no BLE manager, system notifications, or defaults writes.
        }
        #endif
        let storage = UserDefaults.standard
        listeningEnabled = storage.bool(forKey: "listeningEnabled")
        selectedName = storage.string(forKey: "selectedName") ?? "尚未选择电脑"
        selectedID = storage.string(forKey: "selectedID").flatMap(UUID.init(uuidString:))
        deliveredIDs = Array((storage.stringArray(forKey: "deliveredIDs") ?? []).suffix(128))
        if let saved = storage.data(forKey: "eventHistory"),
           let decoded = try? JSONDecoder().decode([EventRecord].self, from: saved) {
            history = Array(decoded.prefix(1))
        } else { history = [] }
        super.init()
        noteConnection(.launched)
        notifications.delegate = self
        setupReports()
        if #available(iOS 18.0, *) { activateAccessorySetup() }
        else { createCentral() }
        _ = publishControlState()
    }

    private func createCentral() {
        guard central == nil else { return }
        if #available(iOS 18.0, *) {
            guard accessories?.claimCentral(for: selectedID) == true else { return }
        }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "local.codex.phone.central.v1",
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    @available(iOS 18.0, *)
    private func activateAccessorySetup() {
        let coordinator = AccessorySetupCoordinator(centralAlreadyCreated: central != nil)
        accessoryCoordinator = coordinator
        accessorySetupReady = false
        accessorySetupText = "正在检查电脑授权"
        coordinator.changed = { [weak self] in self?.accessoryStateChanged() }
        coordinator.failed = { [weak self] message in self?.lastError = message }
        coordinator.picked = { [weak self] id in
            guard let self, let command = self.accessoryPickerCommand,
                  self.controlCommands.isCurrent(command),
                  let computer = self.accessories?.authorization.computers.first(where: { $0.id == id }) else { return }
            self.selectAuthorizedComputer(computer, enable: true)
        }
        coordinator.activate()
    }

    @available(iOS 18.0, *)
    private func accessoryStateChanged() {
        guard let state = accessories?.authorization else { return }
        accessoryPickerActive = state.pickerActive
        accessorySetupReady = state.phase == .ready
        if !state.pickerActive { accessoryPickerCommand = nil }
        computers = state.computers.map { ComputerChoice(id: $0.id, name: $0.name, signal: 0) }
        if state.permits(selectedID) {
            if accessoryNeedsAuthorization { noteConnection(.authorized) }
            accessoryNeedsAuthorization = false
            accessorySetupText = "已获系统配件授权"
            if let computer = state.computers.first(where: { $0.id == selectedID }), selectedName != computer.name {
                selectedName = computer.name; defaults.set(computer.name, forKey: "selectedName")
            }
            createCentral()
            if listeningEnabled { resumeConnection() }
        } else if state.phase == .ready && state.migrationID == nil {
            if !accessoryNeedsAuthorization { noteConnection(.authorizationLost) }
            accessoryNeedsAuthorization = true
            accessorySetupText = "请授权这台电脑"
            // A revoked or missing OS grant must not leave a deceptively enabled control.
            if central != nil { stopSessionConnection() }
            if listeningEnabled { setListeningEnabled(false) }
            connectionText = "完成一次电脑授权后，即可用控制中心开启。"
        } else if state.phase == .failed {
            accessoryNeedsAuthorization = true
            accessorySetupText = "配件授权暂时不可用"
            if central != nil { stopSessionConnection() }
            setListeningEnabled(false)
        }
    }

    @available(iOS 18.0, *)
    private func selectAuthorizedComputer(_ computer: AccessoryAuthorization.Computer, enable: Bool) {
        guard accessories?.authorization.permits(computer.id) == true else { return }
        _ = controlCommands.begin()
        stopSessionConnection()
        selectedID = computer.id; selectedName = computer.name
        defaults.set(computer.id.uuidString, forKey: "selectedID")
        defaults.set(computer.name, forKey: "selectedName")
        accessoryNeedsAuthorization = false
        accessorySetupText = "已获系统配件授权"
        setListeningEnabled(enable)
        createCentral()
        resumeConnection()
    }

    func authorizeComputer() {
        guard usesAccessorySetup, #available(iOS 18.0, *), let accessories,
              accessories.authorization.phase == .ready, !accessories.authorization.pickerActive else { return }
        accessoryPickerCommand = controlCommands.begin()
        lastError = nil
        accessories.showPicker(selected: selectedID, name: selectedName)
    }

    func applicationBecameActive() {
        guard !Self.isDesignPreview else { return }
        if Self.isControlUITest { _ = publishControlState(); return }
        // Recover an invalid OS session on a real user action, never in an automatic retry loop.
        if #available(iOS 18.0, *), accessories?.authorization.phase == .failed { activateAccessorySetup() }
        refreshNotificationSettings()
        _ = publishControlState()
        if listeningEnabled { resumeConnection() }
    }

    func requestNotificationPermission() {
        guard !Self.isDesignPreview else { return }
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyNotificationSettings(settings)
                if self.notificationNeedsSettings {
                    self.openSettings()
                    return
                }
                guard settings.authorizationStatus == .notDetermined else { return }
                self.notifications.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
                    DispatchQueue.main.async {
                        if let error { self?.lastError = "通知授权失败：\(error.localizedDescription)" }
                        self?.refreshNotificationSettings()
                    }
                }
            }
        }
    }

    func refreshNotificationSettings() {
        guard !Self.isDesignPreview, !Self.isControlUITest else { return }
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasAllowed = self.notificationsAllowed
                self.applyNotificationSettings(settings)
                if !wasAllowed && self.notificationsAllowed && self.listeningEnabled {
                    // The computer retains unacknowledged events. Read once after permissions change.
                    if let target = self.peripheral, target.state == .connected,
                       let event = self.eventCharacteristic, event.isNotifying {
                        target.readValue(for: event)
                    }
                }
            }
        }
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            notificationsAllowed = settings.alertSetting == .enabled
            notificationText = notificationsAllowed ? "通知已开启" : "请在设置中开启提醒显示"
            if notificationsAllowed && settings.alertStyle == .none {
                notificationText = "通知已允许 · 横幅关闭"
            }
        case .provisional:
            notificationsAllowed = settings.alertSetting == .enabled
            notificationText = "临时授权，通知可能静默显示"
        case .denied:
            notificationsAllowed = false
            notificationText = "通知被关闭，请到系统设置开启"
        case .notDetermined:
            notificationsAllowed = false
            notificationText = "需要允许通知"
        @unknown default:
            notificationsAllowed = false
            notificationText = "无法确认通知权限"
        }
        if notificationsAllowed && settings.soundSetting != .enabled {
            notificationText += " · 声音未开启"
        }
        notificationNeedsSettings = settings.authorizationStatus != .notDetermined && !notificationsAllowed
        let diagnostics = "横幅：\(settings.alertStyle == .none ? "关闭" : "开启")"
            + " · 锁屏：\(settingLabel(settings.lockScreenSetting))"
            + " · 声音：\(settingLabel(settings.soundSetting))"
            + " · 通知中心：\(settingLabel(settings.notificationCenterSetting))"
            + " · 摘要：\(settingLabel(settings.scheduledDeliverySetting))"
        if notificationDiagnostics != diagnostics { notificationDiagnostics = diagnostics }
    }

    private func settingLabel(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: return "开启"
        case .disabled: return "关闭"
        case .notSupported: return "不适用"
        @unknown default: return "未知"
        }
    }

    func openSettings() {
        guard !Self.isDesignPreview else { return }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func scan() {
        guard !Self.isDesignPreview else { return }
        guard let central, central.state == .poweredOn else { updateBluetoothStatus(); return }
        lastError = nil
        if !usesAccessorySetup { computers = [] }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        isScanning = true
        if !isConnected { connectionText = "正在寻找电脑" }
    }

    func stopScan() {
        guard !Self.isDesignPreview else { return }
        central?.stopScan()
        isScanning = false
        if !listeningEnabled { connectionText = "提醒已暂停" }
    }

    func selectComputer(_ choice: ComputerChoice) {
        guard !Self.isDesignPreview else { return }
        if #available(iOS 18.0, *) {
            guard let computer = accessories?.authorization.computers.first(where: { $0.id == choice.id }) else { return }
            selectAuthorizedComputer(computer, enable: true)
            return
        }
        guard let target = knownPeripherals[choice.id] else { return }
        _ = controlCommands.begin()
        stopSessionConnection()
        selectedID = choice.id
        selectedName = choice.name
        defaults.set(choice.id.uuidString, forKey: "selectedID")
        defaults.set(choice.name, forKey: "selectedName")
        setListeningEnabled(true)
        peripheral = target
        resumeConnection()
    }

    func startListening() {
        guard !Self.isDesignPreview else { return }
        _ = controlCommands.begin()
        if usesAccessorySetup, #available(iOS 18.0, *), accessories?.authorization.permits(selectedID) != true {
            lastError = "请先完成电脑授权，再开启提醒。"
            return
        }
        setListeningEnabled(true)
        if recovery.pausedByRejections { recovery.reset() }
        if Self.isControlUITest {
            isConnected = true
            connectionText = "模拟连接"
            return
        }
        lastError = nil
        resumeConnection()
        if selectedID == nil { scan() }
    }

    @MainActor
    func stopListening() {
        guard !Self.isDesignPreview else { return }
        _ = controlCommands.begin()
        setListeningEnabled(false)
        if Self.isControlUITest {
            isConnected = false
            connectionText = "提醒已暂停"
            return
        }
        stopSessionConnection()
        connectionText = "提醒已暂停"
    }

    @MainActor
    func toggleListeningFromControl() async throws -> String {
        try await setListeningFromControl(controlCommands.toggledTarget(current: listeningEnabled))
    }

    @MainActor
    func setListeningFromControl(_ enabled: Bool) async throws -> String {
        guard CodexModeStore.live.isAvailable else { throw CodexModeStoreError.unavailable }
        if Self.isControlUITest {
            enabled ? startListening() : stopListening()
            guard publishControlState() else { throw CodexModeStoreError.invalidState }
            return enabled ? "模拟器：已开启" : "模拟器：已关闭"
        }
        // Pause is unconditional, including when permissions have been revoked.
        if !enabled {
            noteConnection(.controlOff)
            stopListening()
            guard publishControlState() else { throw CodexModeStoreError.invalidState }
            return "提醒已暂停"
        }
        let command = controlCommands.begin(pendingTarget: true)
        noteConnection(.controlOn)
        defer { controlCommands.finish(command) }
        guard selectedID != nil else { throw CodexModeError.chooseComputer }
        if #available(iOS 18.0, *), accessories?.authorization.phase == .failed { activateAccessorySetup() }
        if #available(iOS 18.0, *), let accessories {
            let ready = await accessories.waitUntilReady()
            guard controlCommands.isCurrent(command) else { throw CodexModeError.superseded }
            guard ready else {
                setListeningEnabled(false)
                throw CodexModeError.accessoryUnavailable
            }
            guard accessories.authorization.permits(selectedID) else { throw CodexModeError.accessoryPermission }
        } else {
            guard CBCentralManager.authorization == .allowedAlways else { throw CodexModeError.bluetoothPermission }
        }
        let settings = await notifications.notificationSettings()
        guard controlCommands.isCurrent(command) else {
            return listeningEnabled ? "已采用最新操作：提醒开启" : "已采用最新操作：提醒暂停"
        }
        applyNotificationSettings(settings)
        guard notificationsAllowed else { throw CodexModeError.notificationPermission }
        // An OS permission change can occur while notificationSettings is suspended.
        if #available(iOS 18.0, *), accessories?.authorization.permits(selectedID) != true {
            throw CodexModeError.accessoryPermission
        }
        if central?.state == .poweredOff { throw CodexModeError.bluetoothOff }
        if central?.state == .unsupported { throw CodexModeError.bluetoothUnsupported }
        // Unknown/resetting is valid during cold launch: didUpdateState resumes later.
        startListening()
        guard publishControlState() else { throw CodexModeStoreError.invalidState }
        return isConnected ? "Codex 模式已开启" : "已开启，等待电脑连接"
    }

    private func setListeningEnabled(_ value: Bool) {
        if listeningEnabled != value {
            listeningEnabled = value
            defaults.set(value, forKey: "listeningEnabled")
        }
        _ = publishControlState()
    }

    @discardableResult
    private func publishControlState() -> Bool {
        do {
            let changed = try CodexModeStore.live.write(listeningEnabled)
            controlStateText = "控制中心状态已同步"
            if changed, #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: CodexModeStore.kind)
            }
            return true
        } catch {
            controlStateText = error.localizedDescription
            return false
        }
    }

    private func noteConnection(_ event: BluetoothDiagnostics.Event, target: CBPeripheral? = nil,
                                error: Error? = nil, reconnecting: Bool = false) {
        let entry = BluetoothDiagnostics.Entry(time: Date().timeIntervalSince1970, event: event,
                     radio: central?.state.rawValue ?? -1, link: (target ?? peripheral)?.state.rawValue,
                     application: UIApplication.shared.applicationState.rawValue,
                     error: error.map { ($0 as NSError).code }, reconnecting: reconnecting,
                     errorDomain: error.map {
                         let domain = ($0 as NSError).domain
                         return domain == CBErrorDomain ? "cb" : (domain == CBATTErrorDomain ? "att" : "other")
                     })
        if connectionDiagnostics.append(entry), let data = connectionDiagnostics.encoded() {
            defaults.set(data, forKey: "bluetoothDiagnostics")
        }
    }

    private func stopSessionConnection() {
        VoiceReporter.shared.end()
        currentAudioRequest = nil; pendingAudio.reset()
        if callRootID != nil { endCallSession() }
        reportQueue.removeAll(); currentFrame = nil; currentBrief = nil; fetchingBrief = false
        pendingPermissionFrames.removeAll(); callMembers.removeAll()
        reportChannel.cancel()
        imageRevision += 1; previewImage = nil
        sessionGeneration += 1
        recovery.reset()
        connectionFailureCode = nil
        noteConnection(.stopped)
        central?.stopScan()
        isScanning = false
        notifications.removePendingNotificationRequests(withIdentifiers: processingIDs.map(notificationID))
        processingIDs.removeAll()
        newestEventID = nil
        if let target = peripheral { central?.cancelPeripheralConnection(target) }
        peripheral = nil
        clearCharacteristics()
    }

    private func clearCharacteristics() {
        let interruptedAudio = currentAudioRequest
        currentAudioRequest = nil
        reservedCallRootID = nil
        if currentFrame != nil || (latestReport?.text.isEmpty == true && latestReport?.kind != 4) {
            resumeReportWhenConnected = true
            reportStatus = "连接中断，重连后继续接收正文"
        }
        reportChannel.reset()
        if let interruptedAudio { VoiceReporter.shared.receiveAudio(interruptedAudio, data: nil) }
        while let request = pendingAudio.pop() { VoiceReporter.shared.receiveAudio(request, data: nil) }
        publishConnection(false)
        preparationInProgress = false
        eventCharacteristic = nil
        ackCharacteristic = nil
        ackQueue.removeAll()
        ackInFlight = nil
    }

    private func publishConnection(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
    }

    private func resumeConnection() {
        guard listeningEnabled, let central, central.state == .poweredOn else { return }
        if #available(iOS 18.0, *), accessories?.authorization.permits(selectedID) != true { return }
        guard !recovery.pausedByRejections else { showRecoveryPause(); return }
        guard let id = selectedID else {
            connectionText = "请选择电脑"
            return
        }
        if peripheral == nil {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first ?? knownPeripherals[id]
        }
        guard let target = peripheral else {
            if !isScanning { scan() }
            connectionText = "正在寻找已保存的电脑"
            return
        }
        target.delegate = self
        if isScanning && !isConnected {
            // The chosen target is retained; connection/notification setup no longer needs scanning.
            central.stopScan()
            isScanning = false
        }
        switch target.state {
        case .connected:
            guard !recovery.isCancelling else { return }
            if eventCharacteristic?.isNotifying != true || ackCharacteristic == nil {
                discover(target)
            }
        case .connecting:
            recovery.adoptPendingConnection()
            connectionText = "正在等待电脑连接"
        case .disconnected:
            guard let delay = recovery.takeConnectDelay(at: ProcessInfo.processInfo.systemUptime) else { return }
            connectionText = delay > 0 ? "正在等待自动重连" : "正在连接 \(selectedName)"
            // Apple owns both the delay and the pending connection while the
            // app is suspended. Never wait for an application timer to reconnect.
            noteConnection(.started, target: target)
            central.connect(target, options: BluetoothConnectionOptions.make(delay: delay))
        case .disconnecting: connectionText = "正在重新连接"
        @unknown default: connectionText = "连接状态未知"
        }
    }

    private func showRecoveryPause() {
        connectionText = "连接受阻 · 请重新开启 Codex 模式"
        let detail = connectionFailureCode.map { "（错误 \($0)）" } ?? ""
        lastError = "蓝牙连续连接失败\(detail)，请在控制中心关闭再开启 Codex 模式。"
    }

    private func discover(_ target: CBPeripheral) {
        guard listeningEnabled, target.identifier == selectedID, target.state == .connected,
              !preparationInProgress, recovery.retryDeadline == nil else { return }
        preparationInProgress = true
        connectionText = "正在准备接收提醒"
        if let service = target.services?.first(where: { $0.uuid == Self.serviceUUID }) {
            if let characteristics = service.characteristics,
               characteristics.contains(where: { $0.uuid == Self.eventUUID }),
               characteristics.contains(where: { $0.uuid == Self.ackUUID }),
               characteristics.contains(where: { $0.uuid == ReportChannel.dataUUID }),
               characteristics.contains(where: { $0.uuid == ReportChannel.requestUUID }) {
                configureCharacteristics(service, on: target)
            } else {
                target.discoverCharacteristics([Self.eventUUID, Self.ackUUID, ReportChannel.dataUUID, ReportChannel.requestUUID], for: service)
            }
        } else { target.discoverServices([Self.serviceUUID]) }
    }

    private func configureCharacteristics(_ service: CBService, on target: CBPeripheral) {
        reportChannel.attach(target, characteristics: service.characteristics ?? [])
        guard let event = service.characteristics?.first(where: { $0.uuid == Self.eventUUID }),
              let ack = service.characteristics?.first(where: { $0.uuid == Self.ackUUID }),
              event.properties.contains(.notify), event.properties.contains(.read),
              ack.properties.contains(.write) else {
            retryConnection(target, message: "电脑的蓝牙提醒服务不完整，请检查电脑端服务。")
            return
        }
        eventCharacteristic = event
        ackCharacteristic = ack
        // Subscribe before reading the cached event to close the connect/read race.
        if event.isNotifying { subscriptionReady(target, event: event) }
        else { target.setNotifyValue(true, for: event) }
    }

    private func subscriptionReady(_ target: CBPeripheral, event: CBCharacteristic) {
        guard listeningEnabled, target.identifier == selectedID, target.state == .connected,
              event.isNotifying else { return }
        preparationInProgress = false
        publishConnection(true)
        recovery.reset()
        connectionFailureCode = nil
        noteConnection(.ready, target: target)
        lastError = nil
        connectionText = "已连接 · 等待 Codex 提醒"
        central?.stopScan()
        isScanning = false
        if let root = callRootID { reportChannel.session(root, active: true) }
        if resumeReportWhenConnected, reportChannel.available {
            resumeReportWhenConnected = false
            reportStatus = "正在恢复本次汇报"
            if let frame = currentFrame { reportChannel.fetch(frame.id, asset: fetchingBrief ? 254 : 0) }
            else if let report = latestReport, report.kind != 4 { retryReport() }
        }
        target.readValue(for: event)
        flushAck()
    }

    private func retryConnection(_ target: CBPeripheral, message: String, disconnect: Bool = true) {
        guard listeningEnabled, let central, central.state == .poweredOn,
              target.identifier == selectedID, target.identifier == peripheral?.identifier else { return }
        // A second callback from a canceled discovery must not move the retry deadline.
        guard let delay = recovery.fail(at: ProcessInfo.processInfo.systemUptime,
                                        disconnected: target.state == .disconnected) else { return }
        clearCharacteristics()
        lastError = message
        connectionText = "\(Int(delay)) 秒后自动重连"
        noteConnection(.retry, target: target)
        if disconnect && target.state != .disconnected {
            central.cancelPeripheralConnection(target)
        } else { resumeConnection() }
    }

    private func receive(_ data: Data, from target: CBPeripheral) {
        guard listeningEnabled, target.identifier == selectedID,
              let frame = EventFrame(data: data) else { return }
        if deliveredIDs.contains(frame.id.uuidString) {
            enqueueAck(frame.data)
            return
        }
        // Persist the call attempt before asking the system, so crash recovery never redials it.
        if defaults.string(forKey: "lastCallAttempt") == frame.id.uuidString {
            rememberDelivered(frame)
            record(frame, delivery: .requestedCall)
            enqueueAck(frame.data)
            return
        }
        guard !processingIDs.contains(frame.id) else { return }
        let outstanding = processingIDs.union(reportQueue.map(\.id)).union(currentFrame.map { [$0.id] } ?? [])
        guard outstanding.count < (frame.kind == .question ? 40 : 32) else {
            reportStatus = "汇报较多，正在依次接收；其余内容请查看电脑。"
            return // Leave it unacknowledged for a bounded sender retry.
        }
        if currentFrame == nil && reportQueue.isEmpty && !VoiceReporter.shared.hasCallSession { failedCallBatch = false }
        newestEventID = frame.id
        processingIDs.insert(frame.id)
        pendingPermissionFrames[frame.id] = frame
        if VoiceReporter.shared.hasCallSession && frame.kind != .question {
            callMembers.insert(frame.id)
            VoiceReporter.shared.expect(frame.id)
            if frame.kind != .custom { _ = VoiceReporter.shared.absorb(.fallback(frame)) }
        }
        beginReport(frame, fetch: false)
        let generation = sessionGeneration
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.listeningEnabled,
                      self.processingIDs.contains(frame.id) else { return }
                self.applyNotificationSettings(settings)
                self.pendingPermissionFrames.removeValue(forKey: frame.id)
                guard self.notificationsAllowed else {
                    self.record(frame, delivery: .awaitingPermission)
                    self.processingIDs.remove(frame.id)
                    self.callMembers.remove(frame.id)
                    VoiceReporter.shared.discardExpectation(frame.id)
                    return
                }
                if frame.kind == .question { self.postNotification(frame, generation: generation); return }
                self.reportQueue.append(frame)
                if VoiceReporter.shared.hasCallSession && frame.kind != .custom {
                    self.finishDelivery(frame) // Accepted by the existing call; never ring again.
                }
                self.pumpReports()
            }
        }
    }

    private func rememberDelivered(_ frame: EventFrame) {
        deliveredIDs.removeAll(where: { $0 == frame.id.uuidString })
        deliveredIDs.append(frame.id.uuidString)
        deliveredIDs = Array(deliveredIDs.suffix(128))
        defaults.set(deliveredIDs, forKey: "deliveredIDs")
    }
    private func finishDelivery(_ frame: EventFrame) {
        guard !deliveredIDs.contains(frame.id.uuidString) else { return }
        processingIDs.remove(frame.id)
        rememberDelivered(frame)
        record(frame, delivery: .scheduled)
        enqueueAck(frame.data)
    }
    private func postNotification(_ frame: EventFrame, generation: Int, completion: (() -> Void)? = nil) {
        if deliveredIDs.contains(frame.id.uuidString) { completion?(); return }
        let content = UNMutableNotificationContent()
        content.title = currentFrame?.id == frame.id ? (currentBrief?.heading ?? frame.kind.label) : frame.kind.label
        content.body = frame.kind == .question ? "Codex 正在等待你的选择，请回到电脑回答。" : "点此查看或听汇报"
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "codex-turns"
        content.categoryIdentifier = frame.kind == .question ? "" : "codex.report"
        content.userInfo = ["eventID": frame.id.uuidString]
        let request = UNNotificationRequest(identifier: notificationID(frame.id), content: content, trigger: nil)
        notifications.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.listeningEnabled,
                      self.processingIDs.contains(frame.id) else { return }
                self.processingIDs.remove(frame.id)
                if error != nil {
                    self.lastError = "系统提醒提交失败"
                    self.record(frame, delivery: .failed)
                    if self.currentFrame?.id == frame.id { self.currentFrame = nil; self.currentBrief = nil; self.pumpReports() }
                    return
                }
                // A successful add confirms system acceptance, not human perception.
                self.finishDelivery(frame)
                completion?()
            }
        }
    }

    private func notificationID(_ id: UUID) -> String { "codex.latest" }

    private func record(_ frame: EventFrame, delivery: EventRecord.Delivery) {
        if let newestEventID, newestEventID != frame.id { return }
        if let index = history.firstIndex(where: { $0.id == frame.id }) {
            guard history[index].delivery != delivery else { return }
            history[index].delivery = delivery
        }
        else { history.insert(EventRecord(id: frame.id, kind: frame.kind, receivedAt: Date(), delivery: delivery), at: 0) }
        history = Array(history.prefix(1))
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "eventHistory") }
    }

    private func enqueueAck(_ data: Data) {
        guard listeningEnabled, !ackQueue.contains(data), ackInFlight != data else { return }
        ackQueue.append(data)
        if ackQueue.count > 128 { ackQueue.removeFirst(ackQueue.count - 128) }
        flushAck()
    }

    private func flushAck() {
        guard listeningEnabled, ackInFlight == nil, let data = ackQueue.first,
              let target = peripheral, target.state == .connected,
              let ack = ackCharacteristic else { return }
        ackQueue.removeFirst()
        ackInFlight = data
        target.writeValue(data, for: ack, type: .withResponse)
    }

    private func updateBluetoothStatus() {
        guard let central else {
            connectionText = accessoryNeedsAuthorization ? "请先授权这台电脑" : "正在检查电脑授权"
            return
        }
        switch central.state {
        case .poweredOn: connectionText = listeningEnabled ? "等待连接电脑" : "提醒已暂停"
        case .poweredOff: connectionText = "蓝牙已关闭，请在控制中心或设置中打开"
        case .unauthorized: connectionText = "蓝牙权限被关闭，请到系统设置开启"
        case .unsupported: connectionText = "这台设备不支持蓝牙低功耗通信"
        case .resetting: connectionText = "蓝牙正在重新启动"
        case .unknown: connectionText = "正在检查蓝牙"
        @unknown default: connectionText = "蓝牙状态未知"
        }
    }
}

extension BluetoothReceiver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        noteConnection(.radio)
        if central.state == .poweredOn {
            restoredToCancel.forEach { central.cancelPeripheralConnection($0) }
            restoredToCancel.removeAll()
            if listeningEnabled { resumeConnection() }
            else {
                central.stopScan()
                isScanning = false
                updateBluetoothStatus()
            }
        } else {
            recovery.reset()
            clearCharacteristics()
            isScanning = false
            updateBluetoothStatus()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for target in restored {
            if listeningEnabled && target.identifier == selectedID {
                peripheral = target
                knownPeripherals[target.identifier] = target
                target.delegate = self
                noteConnection(.restored, target: target)
            } else { restoredToCancel.append(target) }
        }
        if central.state == .poweredOn {
            restoredToCancel.forEach { central.cancelPeripheralConnection($0) }
            restoredToCancel.removeAll()
            resumeConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover target: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        knownPeripherals[target.identifier] = target
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? target.name ?? "Codex 电脑"
        let choice = ComputerChoice(id: target.identifier, name: name, signal: RSSI.intValue)
        if let index = computers.firstIndex(where: { $0.id == choice.id }) { computers[index] = choice }
        else { computers.append(choice) }
        computers.sort { $0.signal > $1.signal }
        if listeningEnabled && target.identifier == selectedID {
            peripheral = target
            resumeConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect target: CBPeripheral) {
        guard listeningEnabled, target.identifier == selectedID else {
            central.cancelPeripheralConnection(target)
            return
        }
        // A late didConnect from the attempt being cancelled cannot restart
        // discovery or erase the pending backoff.
        guard !recovery.isCancelling else { central.cancelPeripheralConnection(target); return }
        recovery.connected()
        peripheral = target
        target.delegate = self
        noteConnection(.connected, target: target)
        resumeConnection()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect target: CBPeripheral, error: Error?) {
        guard listeningEnabled, target.identifier == selectedID, target.identifier == peripheral?.identifier,
              recovery.connectionFailed(at: ProcessInfo.processInfo.systemUptime,
                                        disconnected: target.state == .disconnected) else { return }
        connectionFailureCode = error.map { ($0 as NSError).code }
        noteConnection(.failed, target: target, error: error)
        if recovery.pausedByRejections { clearCharacteristics(); showRecoveryPause(); return }
        retryConnection(target, message: "连接失败：\(error?.localizedDescription ?? "电脑可能不在附近")", disconnect: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral target: CBPeripheral, error: Error?) {
        handleDisconnection(target, isReconnecting: false, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral target: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleDisconnection(target, isReconnecting: isReconnecting, error: error)
    }

    private func handleDisconnection(_ target: CBPeripheral, isReconnecting: Bool, error: Error?) {
        guard target.identifier == peripheral?.identifier, target.state != .connected else { return }
        noteConnection(.disconnected, target: target, error: error, reconnecting: isReconnecting)
        clearCharacteristics()
        if listeningEnabled {
            guard !recovery.pausedByRejections else { showRecoveryPause(); return }
            if recovery.disconnected(systemReconnecting: isReconnecting) {
                // A failed setup retains its deadline. Submit the remaining
                // delay to CoreBluetooth now, before the app can be suspended.
                resumeConnection()
            } else {
                // CoreBluetooth owns the pending connection while the app is suspended.
                connectionText = "正在等待电脑连接"
            }
        } else { connectionText = "提醒已暂停" }
    }
}

extension BluetoothReceiver: CBPeripheralDelegate {
    func peripheral(_ target: CBPeripheral, didDiscoverServices error: Error?) {
        guard listeningEnabled, target.identifier == selectedID,
              target.state == .connected, recovery.retryDeadline == nil else { return }
        if let error {
            retryConnection(target, message: "读取蓝牙服务失败：\(error.localizedDescription)")
            return
        }
        guard let service = target.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            retryConnection(target, message: "没有找到 Codex 提醒服务，请确认电脑端正在运行。")
            return
        }
        target.discoverCharacteristics([Self.eventUUID, Self.ackUUID, ReportChannel.dataUUID, ReportChannel.requestUUID], for: service)
    }

    func peripheral(_ target: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard listeningEnabled, target.identifier == selectedID, service.uuid == Self.serviceUUID,
              target.state == .connected, recovery.retryDeadline == nil else { return }
        if let error {
            retryConnection(target, message: "读取提醒通道失败：\(error.localizedDescription)")
            return
        }
        configureCharacteristics(service, on: target)
    }

    func peripheral(_ target: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if target.identifier == selectedID, characteristic.uuid == ReportChannel.dataUUID {
            reportChannel.subscribed(error); return
        }
        guard listeningEnabled, target.identifier == selectedID, characteristic.uuid == Self.eventUUID,
              target.state == .connected, recovery.retryDeadline == nil else { return }
        if let error {
            retryConnection(target, message: "订阅提醒失败：\(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            retryConnection(target, message: "蓝牙提醒订阅已停止，正在恢复。")
            return
        }
        subscriptionReady(target, event: characteristic)
    }

    func peripheral(_ target: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if listeningEnabled, target.identifier == selectedID, characteristic.uuid == ReportChannel.dataUUID {
            if error == nil, let data = characteristic.value { reportChannel.receive(data) }
            return
        }
        guard listeningEnabled, target.identifier == selectedID, characteristic.uuid == Self.eventUUID else { return }
        if let error { lastError = "接收提醒失败：\(error.localizedDescription)"; return }
        if let data = characteristic.value { receive(data, from: target) }
    }

    func peripheral(_ target: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if target.identifier == selectedID, characteristic.uuid == ReportChannel.requestUUID {
            reportChannel.wrote(error); return
        }
        guard target.identifier == peripheral?.identifier, characteristic.uuid == Self.ackUUID else { return }
        ackInFlight = nil
        if let error {
            // The PC retries its cached event. Persistent deduplication prevents another notification.
            lastError = "确认回执未发出，电脑会重试：\(error.localizedDescription)"
        }
        flushAck()
    }

    func peripheral(_ target: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard listeningEnabled, target.identifier == selectedID,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        retryConnection(target, message: "电脑的蓝牙服务已变化，正在重新连接。")
    }
}

extension BluetoothReceiver: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            defer { completionHandler() }
            self.showReport = true
            let id = response.notification.request.content.userInfo["eventID"] as? String
            if response.actionIdentifier == "codex.listen", id == self.latestReport?.id.uuidString {
                self.listenToLatest()
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
