import SwiftUI

/// One automatic recording attempt per foreground visit on watchOS.
/// Inactivity (including wrist-down) does not begin a new visit. Backgrounding
/// rearms the policy, including when an inactive phase precedes activation.
struct RecordingAutoStartPolicy {
    private var hasUsedVisit = false

    mutating func recordingRequested() {
        hasUsedVisit = true
    }

    mutating func shouldStart(
        in phase: ScenePhase,
        enabled: Bool,
        isConfigured: Bool,
        isIdle: Bool
    ) -> Bool {
        if phase == .background {
            hasUsedVisit = false
            return false
        }
        guard phase == .active else { return false }

        // A recording/submission carried over from the previous visit counts
        // too; completing it must not cause a later callback to start another.
        guard isIdle else {
            hasUsedVisit = true
            return false
        }
        guard enabled, isConfigured, !hasUsedVisit else { return false }
        // Consume before requesting permission or starting the async engine.
        // Errors and permission prompts must not turn wrist raises into retries.
        hasUsedVisit = true
        return true
    }
}
