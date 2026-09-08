#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// CI-only rendered previews of the same views used by the Widget extension.
/// This type and its fixture data are excluded from every device build.
struct WidgetDesignPreviewScreen: View {
    private let sample = CodexActivityAttributes.ContentState(
        phase: .turnEnded,
        isConnected: true,
        latestMessage: "本轮处理结束",
        receivedAt: Date(),
        count: 3,
        lastEventID: UUID()
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Midnight Signal")
                    .font(.system(size: 27, weight: .semibold))
                Text("Widget 视图预览 · 模拟器专用")
                    .font(.system(size: 12))
                    .foregroundStyle(CodexActivityStyle.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                label("紧凑与最小")
                HStack(spacing: 38) {
                    HStack(spacing: 76) {
                        CodexCompactActivityLeading()
                        CodexCompactActivityTrailing(state: sample)
                    }
                    CodexMinimalActivityView(state: sample)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(CodexActivityStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 14) {
                label("展开内容")
                CodexExpandedActivityRow(state: sample)
                    .padding(16)
                    .background(CodexActivityStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            }

            VStack(alignment: .leading, spacing: 14) {
                label("锁屏实时活动")
                CodexLockScreenActivityCard(state: sample)
                    .background(CodexActivityStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            }

            Text("此页复用实际扩展视图。系统决定灵动岛的形状、位置与展开方式。")
                .font(.system(size: 11))
                .foregroundStyle(CodexActivityStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(CodexActivityStyle.secondary)
    }
}
#endif
