import SwiftUI
import Testing
@testable import InstantHermes

struct RecordingAutoStartPolicyTests {
    private func trigger(
        _ policy: inout RecordingAutoStartPolicy,
        _ phase: ScenePhase = .active,
        configured: Bool = true,
        idle: Bool = true,
        enabled: Bool = true
    ) -> Bool {
        policy.shouldStart(in: phase, enabled: enabled, isConfigured: configured, isIdle: idle)
    }

    @Test func launchWaitsForActiveAndCoalescesAppearanceAndActivation() {
        var policy = RecordingAutoStartPolicy()
        #expect(!trigger(&policy, .inactive))
        #expect(trigger(&policy))
        #expect(!trigger(&policy))
    }

    @Test func finishingOrFailingDoesNotRestartOnWristRaiseOrAppearance() {
        var policy = RecordingAutoStartPolicy()
        #expect(trigger(&policy))
        // After acceptance, cancellation, or a failed start, the caller is idle.
        // Repeated appearance/config callbacks and wrist cycles must stay idle.
        for _ in 0..<3 {
            #expect(!trigger(&policy))
            #expect(!trigger(&policy, .inactive))
            #expect(!trigger(&policy))
        }
    }

    @Test func backgroundRearmsAcrossIntermediateInactivePhase() {
        var policy = RecordingAutoStartPolicy()
        #expect(trigger(&policy))
        #expect(!trigger(&policy, .inactive))
        #expect(!trigger(&policy, .background))
        #expect(!trigger(&policy, .inactive))
        #expect(trigger(&policy))
        #expect(!trigger(&policy))
    }

    @Test func delayedConfigurationStartsOnlyWhenActiveAndOnlyOnce() {
        var policy = RecordingAutoStartPolicy()
        #expect(!trigger(&policy, configured: false))
        #expect(!trigger(&policy, .inactive))
        #expect(trigger(&policy))
        #expect(!trigger(&policy, configured: false))
        #expect(!trigger(&policy))
    }

    @Test func configurationInBackgroundWaitsForActivation() {
        var policy = RecordingAutoStartPolicy()
        #expect(!trigger(&policy, .background, configured: false))
        #expect(!trigger(&policy, .background))
        #expect(!trigger(&policy, .inactive))
        #expect(trigger(&policy))
    }

    @Test func manualRecordingConsumesVisitButBackgroundStillRearms() {
        var policy = RecordingAutoStartPolicy()
        policy.recordingRequested()
        #expect(!trigger(&policy, .inactive))
        #expect(!trigger(&policy))
        #expect(!trigger(&policy, .background))
        #expect(trigger(&policy))
    }

    @Test func existingRecordingOrSubmissionConsumesNewVisit() {
        var policy = RecordingAutoStartPolicy()
        #expect(trigger(&policy))
        #expect(!trigger(&policy, .background, idle: false))
        #expect(!trigger(&policy, .inactive, idle: false))
        #expect(!trigger(&policy, idle: false))
        #expect(!trigger(&policy))
        #expect(!trigger(&policy, .inactive))
        #expect(!trigger(&policy))
    }

    @Test func disabledAutoStartNeverRequestsRecording() {
        var policy = RecordingAutoStartPolicy()
        #expect(!trigger(&policy, enabled: false))
        #expect(!trigger(&policy, .background, enabled: false))
        #expect(!trigger(&policy, enabled: false))
    }
}
