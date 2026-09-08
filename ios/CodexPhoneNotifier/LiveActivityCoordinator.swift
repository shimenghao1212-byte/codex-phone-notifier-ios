import ActivityKit

/// Migration only: dismiss any Live Activities left by version 1.1.
/// The banner-only app never creates, updates, or observes an activity.
@MainActor
enum LegacyActivityCleanup {
    private static var cleanupTask: Task<Void, Never>?

    static func endAll() {
        guard cleanupTask == nil else { return }
        let existing = Activity<CodexActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        cleanupTask = Task { @MainActor in
            defer { cleanupTask = nil }
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
