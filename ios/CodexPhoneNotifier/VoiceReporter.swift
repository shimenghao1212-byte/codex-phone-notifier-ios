import Foundation
import Combine
import AVFoundation
import CallKit
import UIKit

protocol SpeechVoiceProviding { func chineseVoice(_ choice: ReportVoice) -> AVSpeechSynthesisVoice? }
final class InstalledChineseVoiceProvider: SpeechVoiceProviding {
    func chineseVoice(_ choice: ReportVoice) -> AVSpeechSynthesisVoice? {
        let gender: AVSpeechSynthesisVoiceGender = choice == .female ? .female : .male
        return AVSpeechSynthesisVoice.speechVoices().filter { ["zh-CN", "zh-TW"].contains($0.language) }.sorted {
            if ($0.language == "zh-CN") != ($1.language == "zh-CN") { return $0.language == "zh-CN" }
            if ($0.gender == gender) != ($1.gender == gender) { return $0.gender == gender }
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.identifier < $1.identifier
        }.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

/// CallKit owns the incoming UI. Speech is produced locally only after acceptance.
final class VoiceReporter: NSObject, ObservableObject, CXProviderDelegate, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceReporter()
    @Published private(set) var state = ""
    @Published private(set) var activeID: UUID?
    @Published private(set) var speaking = false
    @Published private(set) var taskCount = 0
    @Published private(set) var namesSnippet = ""
    @Published private(set) var omittedReportCount = 0
    @Published var voiceChoice = ReportVoice(rawValue: UserDefaults.standard.string(forKey: "reportVoice") ?? "") ?? .female {
        didSet { UserDefaults.standard.set(voiceChoice.rawValue, forKey: "reportVoice") }
    }
    @Published private(set) var voiceNotice = ""
    private var omittedIDs: Set<UUID> = []
    var accepted: ((UUID) -> Void)?
    var ended: ((UUID) -> Void)?
    var omitted: (() -> Void)?
    var audioRequested: ((AudioSegmentRequest) -> Void)?
    var audioCancelled: ((UUID) -> Void)?
    var voiceUnavailable: ((String) -> Void)?
    private var provider: CXProvider?
    private var speech: AVSpeechSynthesizer?
    private var player: AVAudioPlayer?
    private var frozenVoice = ReportVoice.female
    private var audioDescriptions: [UUID: ReportAudio] = [:]
    private var currentPart: SpeechPart?
    private var currentAudio: ReportAudio?
    private var playingSegment = -1
    private var nextAudio = AudioPrefetchBuffer()
    private var audioGate = AudioRequestGate()
    private var audioTimeout: DispatchWorkItem?
    private var playbackTimeout: DispatchWorkItem?
    private var failedAudio = false
    private var previewOnly = false
    private var batch = CallReportBatch()
    private var texts = BoundedSpeechQueue()
    private let voiceProvider: SpeechVoiceProviding
    private var awaitedBodies: Set<UUID> = []
    private var receivingBody: (id: UUID, deadline: BodyWaitDeadline)?
    private var idleWaitStartedAt: TimeInterval?
    var hasCallSession: Bool { activeID != nil && !localPlayback }
    var isAccepted: Bool { activeID != nil && answered }
    var activeMembers: [ReportMember] {
        var keys: Set<String> = []
        return Array(batch.items.flatMap(\.members).filter { keys.insert($0.stableKey).inserted }.prefix(32))
    }
    func contains(_ id: UUID) -> Bool { batch.contains(id) }
    init(voiceProvider: SpeechVoiceProviding = InstalledChineseVoiceProvider()) {
        self.voiceProvider = voiceProvider; super.init()
    }
    private var answered = false
    private var audioReady = false
    private var localPlayback = false
    private var timeout: DispatchWorkItem?

    private func ensureProvider() {
        guard provider == nil else { return }
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        configuration.iconTemplateImageData = UIImage(systemName: "terminal")?.pngData()
        provider = CXProvider(configuration: configuration)
        provider?.setDelegate(self, queue: .main)
    }
    private func callUpdate() -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Codex")
        update.localizedCallerName = String((batch.title + (batch.namesSnippet.isEmpty ? "" : " · " + batch.namesSnippet)).prefix(80))
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        return update
    }
    @discardableResult func absorb(_ brief: ReportBrief) -> Bool {
        guard batch.absorb(brief) else {
            if !omittedIDs.contains(brief.id), omittedIDs.count < 32 { omittedIDs.insert(brief.id); omittedReportCount += 1 }
            omitted?()
            return false
        }
        taskCount = batch.taskCount; namesSnippet = batch.namesSnippet
        if let id = activeID, !localPlayback { provider?.reportCall(with: id, updated: callUpdate()) }
        return true
    }
    func expect(_ id: UUID) { if awaitedBodies.count < 32 { awaitedBodies.insert(id) } }
    func bodyProgress(id: UUID, offset: Int) {
        guard activeID != nil, awaitedBodies.contains(id) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if offset == 0 {
            if receivingBody?.id != id { receivingBody = (id, BodyWaitDeadline(at: now)) }
        } else if receivingBody?.id == id {
            receivingBody?.deadline.progress(at: now)
        }
    }
    func discardExpectation(_ id: UUID, finishIfIdle: Bool = true) {
        awaitedBodies.remove(id)
        if receivingBody?.id == id { receivingBody = nil; idleWaitStartedAt = nil }
        if finishIfIdle { speakIfReady() }
    }
    func present(id: UUID, brief: ReportBrief? = nil, completion: @escaping (Bool) -> Void) {
        let metadata = brief ?? .fallback(EventFrame(id: id, kind: .turnEnded))
        if hasCallSession { if absorb(metadata) { expect(id) }; completion(true); return }
        end(); ensureProvider(); _ = absorb(metadata); expect(id)
        activeID = id; frozenVoice = voiceChoice; voiceNotice = ""; state = "正在呼叫"
        provider?.reportNewIncomingCall(with: id, update: callUpdate()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.activeID == id else { completion(true); return }
                if error != nil {
                    self.reset()
                    completion(false)
                } else {
                    self.state = "等待接听"
                    self.scheduleTimeout(id, seconds: 30)
                    completion(true)
                }
            }
        }
    }
    func supply(id: UUID, text: String, audio: ReportAudio? = nil) {
        guard activeID != nil, batch.contains(id) else { return }
        awaitedBodies.remove(id)
        if receivingBody?.id == id { receivingBody = nil; idleWaitStartedAt = nil }
        guard !texts.contains(id) else { speakIfReady(); return }
        let before = texts.truncatedReports
        let enqueued = texts.enqueue(id: id, text: SpeechText.clean(text))
        if enqueued, let audio, audio.valid { audioDescriptions[id] = audio }
        if !enqueued || texts.truncatedReports > before {
            omitted?()
        }
        speakIfReady()
    }
    func listen(id: UUID, text: String, brief: ReportBrief? = nil, audio: ReportAudio? = nil, preview: Bool = false) {
        if hasCallSession { supply(id: id, text: text, audio: audio); return }
        end()
        activeID = id; answered = true; localPlayback = true; frozenVoice = voiceChoice
        previewOnly = preview; voiceNotice = ""
        _ = absorb(brief ?? .fallback(EventFrame(id: id, kind: .turnEnded)))
        _ = texts.enqueue(id: id, text: SpeechText.clean(text))
        if let audio, audio.valid { audioDescriptions[id] = audio }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            audioReady = true
            if !preview { accepted?(id) }
            speakIfReady()
        } catch { state = "暂时无法播放语音"; reset(keepState: true) }
    }
    private func speakIfReady() {
        guard answered, audioReady, !speaking, currentPart == nil else { return }
        guard let part = texts.pop() else {
            if awaitedBodies.isEmpty { end() }
            else { state = "正在接收汇报"; if let id = activeID { scheduleBodyWait(id) } }
            return
        }
        timeout?.cancel(); timeout = nil; idleWaitStartedAt = nil
        currentPart = part
        currentAudio = audioDescriptions.removeValue(forKey: part.id)
        playingSegment = -1; failedAudio = false
        if currentAudio != nil, audioRequested != nil {
            state = "正在准备自然语音"
            requestAudioSegment(0)
        } else if previewOnly {
            failAudio()
        } else {
            showVoiceNotice("当前使用手机系统语音；连接已配置离线声库的电脑可使用自然语音。")
            speakNative(part)
        }
    }
    private func speakNative(_ part: SpeechPart) {
        if speech == nil {
            speech = AVSpeechSynthesizer(); speech?.delegate = self
            speech?.usesApplicationAudioSession = true
        }
        let utterance = AVSpeechUtterance(string: part.text)
        utterance.voice = voiceProvider.chineseVoice(frozenVoice)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaking = true; state = "正在汇报 · \(taskCount) 个任务"
        speech?.speak(utterance)
    }
    private func showVoiceNotice(_ message: String) {
        voiceNotice = message; voiceUnavailable?(message)
    }
    private func requestAudioSegment(_ index: Int) {
        guard let part = currentPart, let descriptor = currentAudio, activeID != nil,
              index < descriptor.segments, audioGate.pending == nil, nextAudio.isEmpty else { return }
        let request = AudioSegmentRequest(id: part.id, voice: frozenVoice, segment: index)
        guard audioGate.begin(request) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.audioGate.pending == request else { return }
            self.audioCancelled?(request.token)
            self.receiveAudio(request, data: nil)
        }
        audioTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
        audioRequested?(request)
    }
    func receiveAudio(_ request: AudioSegmentRequest, data: Data?) {
        guard activeID != nil, currentPart?.id == request.id, audioGate.accept(request) else { return }
        audioTimeout?.cancel(); audioTimeout = nil
        guard let data, !data.isEmpty, data.count <= ReportAudio.maximumBytes else {
            failAudio(); return
        }
        if player != nil {
            guard request.segment == playingSegment + 1, nextAudio.store(index: request.segment, data: data) else { failAudio(); return }
        } else { playAudio(data, index: request.segment) }
    }
    private func playAudio(_ data: Data, index: Int) {
        guard activeID != nil, answered, audioReady, currentPart != nil else { return }
        do {
            let candidate = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            guard candidate.duration.isFinite, candidate.duration > 0, candidate.duration <= 90 else { failAudio(); return }
            candidate.delegate = self
            guard candidate.prepareToPlay(), candidate.play() else { failAudio(); return }
            player = candidate; playingSegment = index; speaking = true
            state = "正在汇报 · \(taskCount) 个任务"
            let work = DispatchWorkItem { [weak self, weak candidate] in
                guard let self, let candidate, self.player === candidate else { return }
                self.player?.delegate = nil; self.player?.stop(); self.player = nil; self.speaking = false
                self.failAudio()
            }
            playbackTimeout?.cancel(); playbackTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + candidate.duration + 5, execute: work)
            if !previewOnly { requestAudioSegment(index + 1) }
        } catch { failAudio() }
    }
    private func failAudio() {
        let pending = audioGate.pending; audioGate.reset()
        audioTimeout?.cancel(); audioTimeout = nil
        if let pending { audioCancelled?(pending.token) }
        failedAudio = true; nextAudio.reset()
        switch AudioFailureDisposition.resolve(preview: previewOnly, hasPlayed: playingSegment >= 0) {
        case .endPreview:
            showVoiceNotice("所选声音暂时无法试听，请确认电脑连接后重试。")
            finishSpokenPart()
        case .nativeReport:
            guard let part = currentPart else { finishSpokenPart(); return }
            currentAudio = nil
            showVoiceNotice("自然语音暂不可用，已改用手机系统语音。")
            speakNative(part)
        case .skipReportRemainder:
            showVoiceNotice("自然语音传输中断，未重播已读内容。剩余文字可在本次汇报中查看。")
            if player == nil { finishSpokenPart() }
        }
    }
    private func finishSpokenPart() {
        playbackTimeout?.cancel(); playbackTimeout = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let pending = audioGate.pending { audioCancelled?(pending.token) }
        audioGate.reset(); audioTimeout?.cancel(); audioTimeout = nil
        currentPart = nil; currentAudio = nil; nextAudio.reset(); speaking = false
        if previewOnly { end() } else { speakIfReady() }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, activeID != nil else { return }
        playbackTimeout?.cancel(); playbackTimeout = nil
        self.player?.delegate = nil; self.player = nil; speaking = false
        guard flag else { failAudio(); return }
        guard !previewOnly, !failedAudio, let descriptor = currentAudio,
              playingSegment + 1 < descriptor.segments else { finishSpokenPart(); return }
        if let next = nextAudio.take() {
            playAudio(next.data, index: next.index)
        } else {
            state = "正在接收下一段语音"
            if audioGate.pending == nil { requestAudioSegment(playingSegment + 1) }
        }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        playbackTimeout?.cancel(); playbackTimeout = nil
        self.player?.delegate = nil; self.player?.stop(); self.player = nil; speaking = false
        failAudio()
    }
    func end() {
        if let id = activeID, !localPlayback { provider?.reportCall(with: id, endedAt: Date(), reason: .remoteEnded) }
        let old = activeID
        reset()
        if let old { ended?(old) }
    }
    private func reset(keepState: Bool = false) {
        timeout?.cancel(); timeout = nil
        speech?.delegate = nil; speech?.stopSpeaking(at: .immediate); speech = nil
        player?.delegate = nil; player?.stop(); player = nil
        playbackTimeout?.cancel(); playbackTimeout = nil
        let pending = audioGate.pending; audioGate.reset()
        audioTimeout?.cancel(); audioTimeout = nil
        currentPart = nil; currentAudio = nil; nextAudio.reset(); audioDescriptions.removeAll()
        playingSegment = -1; failedAudio = false; previewOnly = false
        if let pending { audioCancelled?(pending.token) }
        if localPlayback { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        activeID = nil; speaking = false; taskCount = 0; namesSnippet = ""
        batch.reset(); texts.reset(); awaitedBodies.removeAll(); omittedIDs.removeAll(); omittedReportCount = 0
        receivingBody = nil; idleWaitStartedAt = nil
        answered = false; audioReady = false; localPlayback = false
        if !keepState { state = "" }
    }
    private func scheduleTimeout(_ id: UUID, seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeID == id else { return }
            self.end()
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func scheduleBodyWait(_ id: UUID) {
        timeout?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        if idleWaitStartedAt == nil { idleWaitStartedAt = now }
        let remaining = receivingBody?.deadline.remaining(at: now)
            ?? max(0, (idleWaitStartedAt ?? now) + 25 - now)
        guard remaining > 0 else { end(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeID == id, self.answered, !self.speaking else { return }
            self.timeout = nil
            // Only accepted body bytes can advance the clock. Briefs/images cannot.
            self.scheduleBodyWait(id)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }
    func providerDidReset(_ provider: CXProvider) {
        let id = activeID
        reset()
        if let id { ended?(id) }
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard activeID == action.callUUID else { action.fail(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            answered = true; state = "正在接收汇报"
            action.fulfill()
            accepted?(action.callUUID)
            timeout?.cancel(); timeout = nil
            if texts.isEmpty { scheduleBodyWait(action.callUUID) }
            else { scheduleTimeout(action.callUUID, seconds: 25) } // Bound audio activation, too.
            speakIfReady()
        } catch { action.fail(); end() }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        guard activeID == action.callUUID else { return }
        let id = activeID
        reset()
        if let id { ended?(id) }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard activeID != nil else { return }
        audioReady = true
        speakIfReady()
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        if activeID != nil && audioReady && !localPlayback { end() }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
        if let call = action as? CXCallAction, call.callUUID == activeID { end() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === speech else { return }
        finishSpokenPart()
    }
}
