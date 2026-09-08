import SwiftUI

extension ThreadColorMap {
    func color(for member: ReportMember) -> Color {
        let rgb = rgb(for: member)
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

/// Tiny neutral-backed labels; color identifies the task, never its result state.
struct ThreadNameTags: View {
    let members: [ReportMember]
    var limit = 3
    var centered = false
    var body: some View {
        let colors = ThreadColorMap(members)
        ThreadTagFlow(centered: centered) {
            ForEach(Array(members.prefix(limit).enumerated()), id: \.offset) { index, member in
                let color = colors.color(for: member)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 4, height: 4).accessibilityHidden(true)
                    Text(member.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color(white: 0.045), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("任务 \(index + 1)：\(member.name)")
            }
            if members.count > limit {
                Text("+\(members.count - limit)").font(.system(size: 11))
                    .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 5)
            }
        }
    }
}
private struct ThreadTagFlow: Layout {
    var centered: Bool
    private let gap: CGFloat = 7
    private func arrange(width: CGFloat, subviews: Subviews) -> (CGSize, [CGRect]) {
        var frames: [CGRect] = []
        var rowStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        func centerRow() {
            guard centered, frames.count > rowStart else { return }
            let adjustment = max(0, (width - max(0, x - gap)) / 2)
            for index in rowStart..<frames.count { frames[index].origin.x += adjustment }
        }
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width {
                centerRow(); rowStart = frames.count; x = 0; y += rowHeight + gap; rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + gap; rowHeight = max(rowHeight, size.height)
        }
        centerRow()
        return (CGSize(width: width, height: frames.isEmpty ? 0 : y + rowHeight), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + gap })
        return arrange(width: width, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: max(1, bounds.width), subviews: subviews).1
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

@MainActor
struct LatestReportView: View {
    @ObservedObject var receiver: BluetoothReceiver
    @ObservedObject private var voice = VoiceReporter.shared
    @State private var zoom: CGFloat = 1
    private let accent = Color(red: 0.43, green: 0.49, blue: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let report = receiver.latestReport {
                    let sections = report.displaySections
                    HStack(spacing: 16) {
                        Image("CodexMark").resizable().scaledToFit().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(report.title).font(.title2.weight(.semibold))
                            if report.brief.taskCount > 1 {
                                Text("\(report.brief.taskCount) 个任务")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Date(timeIntervalSince1970: report.endedAt), format: .dateTime.hour().minute())
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if !report.brief.members.isEmpty { ThreadNameTags(members: report.brief.members) }
                    if voice.activeID != nil {
                        Label(voice.state, systemImage: voice.speaking ? "speaker.wave.2" : "phone")
                            .font(.subheadline).foregroundStyle(accent)
                        if !voice.activeMembers.isEmpty { ThreadNameTags(members: voice.activeMembers) }
                    }
                    if report.text.isEmpty {
                        Text("正在接收本次汇报…").foregroundStyle(.secondary)
                    } else if !sections.isEmpty {
                        let colors = ThreadColorMap(report.brief.members)
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(sections, id: \.offset) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    if let member = section.member {
                                        HStack(spacing: 8) {
                                            RoundedRectangle(cornerRadius: 1).fill(colors.color(for: member)).frame(width: 2, height: 14)
                                                .accessibilityHidden(true)
                                            Text(member.name).font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(colors.color(for: member))
                                        }
                                    }
                                    Text(section.text).font(.system(size: 17)).lineSpacing(7)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        Text(report.text).font(.system(size: 17)).lineSpacing(7)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !receiver.reportStatus.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(receiver.reportStatus).font(.footnote).foregroundStyle(.secondary)
                            if report.text.isEmpty || receiver.reportStatus.contains("未") || receiver.reportStatus.contains("失败") {
                                Button("重新接收正文") { receiver.retryReport() }.font(.subheadline)
                            }
                        }
                    }
                    if !report.images.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("本次图片").font(.headline)
                            ForEach(report.images) { asset in
                                Button { zoom = 1; receiver.loadImage(asset.index) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "photo").foregroundStyle(accent)
                                        Text(asset.name).lineLimit(1).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if let image = receiver.previewImage {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(maxHeight: 320)
                                    .scaleEffect(zoom)
                                    .gesture(MagnificationGesture().onChanged { zoom = min(max($0, 1), 3) })
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .onTapGesture(count: 2) { zoom = 1 }
                                    .accessibilityLabel("本次任务图片，双指放大，双击复位")
                            }
                            Text("接听或点选后传输预览，离开页面释放图片。原图保留在电脑。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 18) {
                        Image("CodexMark").resizable().scaledToFit().frame(width: 64, height: 64)
                        Text("等待下一次完成").font(.title2.weight(.semibold))
                        Text("最新的汇报会出现在这里。").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 90)
                }
            }.padding(26)
        }
        .background(Color.black)
        .safeAreaInset(edge: .bottom) {
            if let report = receiver.latestReport {
                VStack(spacing: 10) {
                    Button {
                        if voice.activeID != nil { VoiceReporter.shared.end() }
                        else { receiver.listenToLatest() }
                    } label: {
                        Label(voice.activeID != nil ? "结束汇报" : "听汇报",
                              systemImage: voice.activeID != nil ? "phone.down.fill" : "play.fill")
                            .font(.system(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(.white)
                            .background(voice.activeID != nil ? Color.red.opacity(0.85) : accent, in: Capsule())
                    }.disabled(report.text.isEmpty && voice.activeID == nil)
                    Text("只保留这一条，下次自动替换。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).padding(.vertical, 12).background(Color.black)
            }
        }
        .navigationTitle("本次汇报")
        .onAppear { receiver.reportVisibilityChanged(true) }
        .onDisappear { receiver.reportVisibilityChanged(false) }
    }
}
