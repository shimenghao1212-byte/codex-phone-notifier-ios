import AppIntents
import SwiftUI
import WidgetKit

@main
struct CodexControls: WidgetBundle {
    var body: some Widget {
        CodexModeControl()
    }
}

struct CodexModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CodexModeStore.kind, provider: ModeProvider()) { enabled in
            ControlWidgetToggle("Codex 模式", isOn: enabled, action: SetCodexModeIntent()) { isOn in
                Label(isOn ? "已开启" : "已关闭", systemImage: "terminal")
            }
            .tint(Color(red: 0.43, green: 0.49, blue: 1))
        }
        .displayName("Codex 模式")
        .description("点一下开启，再点一下暂停。")
    }
}

private struct ModeProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { try CodexModeStore.live.read() }
}
