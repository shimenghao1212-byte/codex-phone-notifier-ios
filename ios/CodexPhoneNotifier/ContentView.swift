import SwiftUI

private enum Midnight {
    static let accent = Color(red: 0.43, green: 0.49, blue: 1)
    static let secondary = Color(white: 0.60)
    static let line = Color(white: 0.14)
}

@MainActor
struct ContentView: View {
    @ObservedObject var receiver: BluetoothReceiver
    @ObservedObject private var voice = VoiceReporter.shared
    @State private var sheet: DetailSheet?

    private enum DetailSheet: String, Identifiable {
        case settings, computers, history
        var id: String { rawValue }
    }
    private var designPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return BluetoothReceiver.isDesignPreview
        #else
        return false
        #endif
    }
    private var connected: Bool { designPreview || receiver.isConnected }
    private var listening: Bool { designPreview || receiver.listeningEnabled }
    private var allowed: Bool { designPreview || receiver.notificationsAllowed }
    private var deviceName: String { designPreview ? "我的电脑" : receiver.selectedName }
    private var headline: String {
        if connected { return "已连接" }
        if receiver.accessoryNeedsAuthorization { return "授权电脑" }
        if receiver.selectedID == nil { return "准备连接" }
        if !listening { return "已暂停" }
        if receiver.connectionText.contains("蓝牙") { return "等待蓝牙" }
        return receiver.isScanning ? "寻找电脑" : "连接中"
    }
    private var subtitle: String {
        if connected { return "结束或异常暂停时，自会提醒。" }
        if receiver.accessoryNeedsAuthorization { return "授权一次，以后从控制中心开启。" }
        if !listening { return "准备好了，再继续。" }
        return receiver.connectionText
    }
    private var primaryTitle: String {
        if !allowed { return "允许通知" }
        if receiver.accessoryNeedsAuthorization { return "授权电脑" }
        if receiver.selectedID == nil && !designPreview { return "连接电脑" }
        return listening ? "暂停提醒" : "开始提醒"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 40)
                    hero
                    Spacer(minLength: 44)
                    controls
                    recentSummary.padding(.top, 28).padding(.bottom, 30)
                }
                .padding(.horizontal, 28)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Midnight.accent)
        .sheet(item: $sheet) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .settings: settings
                    case .computers: computers
                    case .history: LatestReportView(receiver: receiver)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { sheet = nil }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(.dark)
            .tint(Midnight.accent)
        }
        .onChange(of: receiver.showReport) { show in
            if show { sheet = .history; receiver.showReport = false }
        }
        .onAppear {
            if receiver.showReport { sheet = .history; receiver.showReport = false }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["CODEX_DESIGN_PREVIEW"] == "report" { sheet = .history }
            if ProcessInfo.processInfo.environment["CODEX_DESIGN_PREVIEW"] == "settings" { sheet = .settings }
            #endif
        }
    }

    private var header: some View {
        Text("Codex")
            .font(.system(size: 22, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 48)
            .overlay(alignment: .trailing) {
                Button { sheet = .settings } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                }.accessibilityLabel("设置")
            }
            .padding(.top, 8)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Image("CodexMark").resizable().scaledToFit()
                .frame(width: 70, height: 70).accessibilityHidden(true)
            Text(headline).font(.system(size: 36, weight: .semibold))
                .tracking(-0.7).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.top, 30)
            Circle().fill(connected ? Midnight.accent : Color(white: 0.34))
                .frame(width: 8, height: 8).padding(.top, 20).accessibilityHidden(true)
            Text(subtitle).font(.system(size: 15))
                .foregroundStyle(Midnight.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 24)
            Button { sheet = .computers } label: {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.system(size: 17))
                    Text(receiver.selectedID == nil && !designPreview ? "选择电脑" : deviceName)
                        .font(.system(size: 15)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.90))
                .frame(maxWidth: .infinity).frame(height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Midnight.line, lineWidth: 0.7))
            }
            .frame(maxWidth: 266).padding(.top, 28)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !designPreview, let error = receiver.lastError {
                Button { sheet = .settings } label: {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.bottom, 8)
            }
            Button(action: primaryAction) {
                Text(primaryTitle).font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity).frame(minHeight: 54)
                    .foregroundStyle(.white).background(Midnight.accent, in: Capsule())
            }
            Button { sheet = .settings } label: {
                Text("通知设置").font(.system(size: 16))
                    .frame(maxWidth: .infinity).frame(minHeight: 52)
                    .foregroundStyle(Midnight.accent)
                    .overlay(Capsule().stroke(Midnight.accent.opacity(0.7), lineWidth: 0.8))
            }
        }
    }

    private func primaryAction() {
        if !receiver.notificationsAllowed {
            receiver.requestNotificationPermission()
        }
        else if receiver.usesAccessorySetup && (receiver.accessoryNeedsAuthorization || receiver.selectedID == nil) {
            sheet = .computers
        } else if receiver.selectedID == nil {
            receiver.startListening()
            sheet = .computers
        } else if receiver.listeningEnabled { receiver.stopListening() }
        else { receiver.startListening() }
    }

    private var recentBrief: ReportBrief? {
        guard let entry = receiver.history.first, let report = receiver.latestReport,
              report.id == entry.id, let heading = report.heading, !heading.isEmpty else { return nil }
        return report.brief
    }

    private var recentSummary: some View {
        Button { sheet = .history } label: {
            VStack(spacing: 6) {
                if let entry = receiver.history.first {
                    HStack(spacing: 9) {
                        Image(systemName: eventSymbol(entry)).font(.system(size: 16))
                            .foregroundStyle(Midnight.accent)
                        Text(recentBrief?.heading ?? entry.kind.label)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    if let brief = recentBrief, !brief.namesSnippet.isEmpty {
                        ThreadNameTags(members: brief.members, centered: true)
                    }
                    Text(entry.receivedAt, format: .dateTime.hour().minute()).font(.system(size: 12))
                } else {
                    Label("还没有新的提醒", systemImage: "bell")
                }
            }
            .font(.system(size: 13)).foregroundStyle(Midnight.secondary)
            .frame(maxWidth: .infinity).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("查看最近提醒")
    }

    private var settings: some View {
        Form {
            Section("通知") {
                Label(receiver.notificationText, systemImage: receiver.notificationsAllowed ? "checkmark.circle" : "bell.slash")
                    .font(.subheadline)
                Text(receiver.notificationDiagnostics).font(.caption).foregroundStyle(.secondary)
                if !receiver.notificationsAllowed {
                    Button("允许通知") { receiver.requestNotificationPermission() }
                }
                Button("打开系统设置") { receiver.openSettings() }
            }
            Section("提醒方式") {
                Picker("提醒方式", selection: $receiver.alertMode) {
                    ForEach(BluetoothReceiver.AlertMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }.pickerStyle(.segmented)
                Text(receiver.alertMode == .call
                     ? "同一次来电汇总任务数量与名称，依次朗读收到的回复。汇报结束后挂断；来电失败时改用普通通知。"
                     : "结束时显示一次简约横幅，可点通知查看或听汇报。")
                    .font(.footnote).foregroundStyle(.secondary)
                if receiver.alertMode == .call {
                    Button("测试来电") { receiver.testIncomingCall() }
                }
            }
            Section("汇报声音") {
                Picker("声音", selection: $voice.voiceChoice) {
                    ForEach(ReportVoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }.pickerStyle(.segmented)
                Button(voice.activeID != nil && !voice.hasCallSession ? "停止试听" : "试听当前声音") {
                    if voice.activeID != nil && !voice.hasCallSession { voice.end() }
                    else { receiver.previewVoice() }
                }.disabled(voice.hasCallSession)
                Text("电脑离线生成普通话语音，手机通过蓝牙播放。试听使用本次汇报的第一段；每通电话保持同一种声音。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !voice.voiceNotice.isEmpty {
                    Text(voice.voiceNotice).font(.caption).foregroundStyle(.secondary)
                }
                if !receiver.reportStatus.isEmpty {
                    Text(receiver.reportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            if #available(iOS 18.0, *) {
                Section("电脑授权") {
                    Label(receiver.accessorySetupText, systemImage: receiver.accessoryNeedsAuthorization ? "desktopcomputer" : "checkmark.shield")
                    Button("管理电脑") { sheet = .computers }
                    Text("通过苹果系统授权这台电脑，用于蓝牙连接与后台恢复。只需设置一次。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("控制中心") {
                    Label("Codex 模式", systemImage: "terminal")
                    Text("下拉控制中心，长按空白处，点“添加控制”，搜索 Codex，添加“Codex 模式”。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("点一下开启并点亮，再点一下关闭并熄灭。开关与 App 内的提醒状态同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(receiver.controlStateText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button { sheet = .computers } label: {
                    LabeledContent("连接电脑", value: receiver.selectedID == nil ? "尚未选择" : receiver.selectedName)
                }
                Button("本次汇报") { sheet = .history }
                Button("清除本次内容", role: .destructive) { receiver.clearLatestReport() }
            }
            if let error = receiver.lastError {
                Section("需要处理") { Text(error).font(.subheadline).foregroundStyle(.orange) }
            }
            Section {
                Text("通过附近蓝牙接收提醒。电脑需保持开机；手机可以锁屏，请不要从多任务界面强制退出 App。")
                Text("正文通过受保护的蓝牙通道传输。图片仅在接听或点选后传输预览，不写入相册；只保留最新一份内容。")
                Text("专注模式、静音与系统设置会影响来电和通知。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("设置")
    }

    private var computers: some View {
        List {
            Section {
                if receiver.usesAccessorySetup {
                    Text(receiver.accessorySetupText).font(.subheadline).foregroundStyle(.secondary)
                    Button(receiver.accessoryPickerActive ? "正在授权" : (receiver.accessoryNeedsAuthorization ? "授权电脑" : "添加电脑")) {
                        receiver.authorizeComputer()
                    }.disabled(!receiver.accessorySetupReady || receiver.accessoryPickerActive)
                    if receiver.accessoryNeedsAuthorization {
                        Text("保持电脑端运行，在苹果弹窗中确认这台电脑。完成后即可从控制中心开启提醒。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button(receiver.isScanning ? "停止寻找" : "寻找电脑") {
                        receiver.isScanning ? receiver.stopScan() : receiver.scan()
                    }
                }
                if receiver.isScanning {
                    Label("正在寻找附近的电脑", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if receiver.computers.isEmpty && !receiver.isScanning {
                    Text("先启动电脑端提醒，再寻找电脑。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(receiver.computers) { computer in
                    Button {
                        receiver.selectComputer(computer)
                        sheet = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                            Text(computer.name).foregroundStyle(.primary)
                            Spacer()
                            if computer.id == receiver.selectedID {
                                Text(receiver.isConnected ? "已连接" : "已选择")
                                    .font(.caption).foregroundStyle(Midnight.accent)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                if let error = receiver.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            } footer: { Text("选择一次后，会自动尝试重新连接。") }
        }
        .navigationTitle("连接电脑")
        .onAppear { if !receiver.usesAccessorySetup && !receiver.isConnected && !receiver.isScanning { receiver.scan() } }
    }

    private var history: some View {
        List {
            if receiver.history.isEmpty {
                Text("收到的提醒会留在这里。").foregroundStyle(.secondary)
            }
            ForEach(receiver.history) { entry in
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: eventSymbol(entry))
                        .foregroundStyle(entry.delivery == .scheduled && entry.kind != .abnormalPaused ? Midnight.accent : .orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.kind.label)
                            .font(.system(size: 16, weight: .medium))
                        Text(entry.delivery.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.receivedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 7)
            }
        }.navigationTitle("最近提醒")
    }

    private func eventSymbol(_ entry: EventRecord) -> String {
        guard entry.delivery == .scheduled else { return "exclamationmark.circle" }
        switch entry.kind {
        case .turnEnded: return "checkmark.circle"
        case .test: return "bell"
        case .abnormalPaused: return "pause.circle"
        case .question: return "questionmark.bubble"
        case .custom: return "message"
        }
    }
}
