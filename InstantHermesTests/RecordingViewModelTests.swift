//
//  RecordingViewModelTests.swift
//  InstantHermesTests
//
//  Regression tests for the cancel path: the UI state machine must reset
//  immediately when the user cancels, even when the backend is unreachable
//  and the service teardown (engine stop, upload-queue drop, cancel POST)
//  is slow. Also covers the connection-lost auto-stop when a chunk upload
//  permanently fails.
//

import Testing
import Foundation
@testable import InstantHermes

/// Mock AudioRecordingService with knobs to simulate slow or failing
/// network teardown (backend unreachable).
final class MockAudioRecordingService: AudioRecordingService {
    var currentRMS: Float = 0
    var hasExceededSilenceThreshold: Bool = false
    var hasUploadError: Bool = false

    /// How long cancel() blocks (simulates a teardown stuck draining an
    /// upload queue that cannot drain during an outage).
    var cancelDelayNanoseconds: UInt64 = 0
    var cancelCallCount = 0

    /// How long submit() blocks (simulates a submit POST in flight).
    var submitDelayNanoseconds: UInt64 = 0
    var submitCallCount = 0

    func requestPermission() async -> Bool { true }

    func start() async throws -> UUID { UUID() }

    func stop() async {}

    func submit(recordingID: UUID, deliveryTarget: String?) async throws {
        submitCallCount += 1
        if submitDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: submitDelayNanoseconds)
        }
    }

    func cancel(recordingID: UUID) async {
        cancelCallCount += 1
        if cancelDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: cancelDelayNanoseconds)
        }
    }
}

@Suite(.serialized)
struct RecordingViewModelTests {

    /// Saves a valid dummy server config so the view model considers itself
    /// configured; removes it again after the test.
    @MainActor
    private func withConfiguredServer(_ body: @MainActor () async throws -> Void) async throws {
        let store = AppConfigStore.shared
        try store.save(ServerConfig(host: "raspi5.tailde040.ts.net", apiKey: "test-key", deliveryTarget: ""))
        defer { store.delete() }
        try await body()
    }

    /// Waits until the condition holds or the timeout elapses.
    @MainActor
    private func waitFor(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Regression test: cancelling during recording must reset the UI to idle
    /// synchronously, even when the backend teardown is slow (backend
    /// unreachable). The old code reset the state only after the service calls
    /// completed, leaving the Cancel button apparently dead.
    @MainActor
    @Test func cancelResetsStateImmediatelyEvenWhenTeardownIsSlow() async throws {
        try await withConfiguredServer {
            let service = MockAudioRecordingService()
            service.cancelDelayNanoseconds = 2_000_000_000
            let viewModel = RecordingViewModel(service: service)

            viewModel.startRecording()
            #expect(await waitFor { viewModel.state == .recording })

            viewModel.cancelRecording()

            // The state machine must reset synchronously — before the slow
            // teardown finishes.
            #expect(viewModel.state == .idle)
            #expect(viewModel.errorMessage == nil)

            // The backend cancel still happens (in the background).
            #expect(await waitFor { service.cancelCallCount == 1 })
        }
    }

    /// Cancelling while the submit POST is in flight must reset the UI
    /// immediately and must not surface a spurious "cancelled" error once
    /// the interrupted submit finishes.
    @MainActor
    @Test func cancelDuringSubmittingResetsImmediatelyWithoutError() async throws {
        try await withConfiguredServer {
            let service = MockAudioRecordingService()
            service.submitDelayNanoseconds = 2_000_000_000
            let viewModel = RecordingViewModel(service: service)

            viewModel.startRecording()
            #expect(await waitFor { viewModel.state == .recording })

            viewModel.submitRecording()
            #expect(viewModel.state == .submitting)

            // Wait until the submit POST is actually in flight.
            #expect(await waitFor { service.submitCallCount == 1 })

            viewModel.cancelRecording()
            #expect(viewModel.state == .idle)

            // After the interrupted submit finishes, no spurious error.
            try await Task.sleep(nanoseconds: 2_500_000_000)
            #expect(viewModel.state == .idle)
            #expect(viewModel.errorMessage == nil)
        }
    }

    /// When a chunk upload permanently fails (backend unreachable), the
    /// recording must stop on its own and show an error instead of recording
    /// into the void until the silence auto-submit fires and fails.
    @MainActor
    @Test func connectionLostStopsRecordingAndShowsError() async throws {
        try await withConfiguredServer {
            let service = MockAudioRecordingService()
            let viewModel = RecordingViewModel(service: service)

            viewModel.startRecording()
            #expect(await waitFor { viewModel.state == .recording })

            // A chunk upload permanently fails.
            service.hasUploadError = true

            // The level timer (30 fps) notices and stops the recording.
            #expect(await waitFor { viewModel.state == .idle })
            #expect(viewModel.errorMessage != nil)

            // The void recording is discarded (best-effort backend cancel).
            #expect(await waitFor { service.cancelCallCount == 1 })
        }
    }
}
