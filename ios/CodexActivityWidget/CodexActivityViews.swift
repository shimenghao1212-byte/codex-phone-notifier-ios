#if WIDGET_EXTENSION || (DEBUG && targetEnvironment(simulator))
import SwiftUI

enum CodexActivityStyle {
    static let accent = Color(red: 0.40, green: 0.48, blue: 1.0)
    static let secondary = Color.white.opacity(0.58)
    static let surface = Color(red: 0.045, green: 0.05, blue: 0.065)

    static func title(for state: CodexActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .turnEnded: return "本轮已完成"
        case .test: return "测试已收到"
        case .disconnected: return "等待连接"
        case .ready: return "提醒已就绪"
        }
    }

    static func subtitle(for state: CodexActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .turnEnded: return "可以回到电脑了"
        case .test: return "蓝牙提醒运行正常"
        case .disconnected: return "靠近电脑后自动重连"
        case .ready: return "结束时，自会提醒。"
        }
    }
}

struct CodexActivityMark: View {
    var size: CGFloat

    var body: some View {
        Image("CodexMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CodexActivityStatusGlyph: View {
    let state: CodexActivityAttributes.ContentState
    var size: CGFloat = 30

    private var symbol: String {
        switch state.phase {
        case .turnEnded, .test: return "checkmark"
        case .disconnected: return "link"
        case .ready: return "wave.3.right"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(state.phase == .disconnected ? CodexActivityStyle.secondary : CodexActivityStyle.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.045)))
            .overlay(Circle().strokeBorder(CodexActivityStyle.accent.opacity(0.20), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}

/// Shared with the simulator gallery so screenshots exercise the shipped view.
struct CodexLockScreenActivityCard: View {
    let state: CodexActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            CodexActivityMark(size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(CodexActivityStyle.title(for: state))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(state.phase == .turnEnded ? "Codex 提醒" : CodexActivityStyle.subtitle(for: state))
                    .font(.system(size: 13))
                    .foregroundStyle(CodexActivityStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            CodexActivityStatusGlyph(state: state, size: 32)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex，\(CodexActivityStyle.title(for: state))，\(CodexActivityStyle.subtitle(for: state))")
    }
}

struct CodexExpandedActivityRow: View {
    let state: CodexActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            CodexActivityMark(size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(CodexActivityStyle.title(for: state))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(CodexActivityStyle.subtitle(for: state))
                    .font(.system(size: 11))
                    .foregroundStyle(CodexActivityStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            CodexActivityStatusGlyph(state: state, size: 28)
        }
        .padding(.horizontal, 5)
        .padding(.top, 4)
        .padding(.bottom, 9)
        .accessibilityElement(children: .combine)
    }
}

struct CodexCompactActivityLeading: View {
    var body: some View { CodexActivityMark(size: 22) }
}

struct CodexCompactActivityTrailing: View {
    let state: CodexActivityAttributes.ContentState
    var body: some View { CodexActivityStatusGlyph(state: state, size: 22) }
}

struct CodexMinimalActivityView: View {
    let state: CodexActivityAttributes.ContentState

    var body: some View {
        if state.phase == .turnEnded || state.phase == .test {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CodexActivityStyle.accent)
                .accessibilityLabel(CodexActivityStyle.title(for: state))
        } else {
            CodexActivityMark(size: 21)
        }
    }
}
#endif
