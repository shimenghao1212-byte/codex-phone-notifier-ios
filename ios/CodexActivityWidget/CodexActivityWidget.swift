import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CodexActivityWidgetBundle: WidgetBundle {
    var body: some Widget { CodexActivityWidget() }
}

struct CodexActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodexActivityAttributes.self) { context in
            CodexLockScreenActivityCard(state: context.state)
                .activityBackgroundTint(CodexActivityStyle.surface)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // The system supplies the camera exclusion area and island mask.
                DynamicIslandExpandedRegion(.bottom) {
                    CodexExpandedActivityRow(state: context.state)
                }
            } compactLeading: {
                CodexCompactActivityLeading()
            } compactTrailing: {
                CodexCompactActivityTrailing(state: context.state)
            } minimal: {
                CodexMinimalActivityView(state: context.state)
            }
            .keylineTint(CodexActivityStyle.accent)
        }
    }
}
