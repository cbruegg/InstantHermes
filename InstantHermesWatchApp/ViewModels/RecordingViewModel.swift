//
//  RecordingViewModel.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//
//  ViewModel for the recording screen. Implements the full state machine:
//  idle → recording → submitting → idle, with Cancel available while recording.
//  Fire and forget: the STT backend transcribes the audio and forwards the
//  transcript to Hermes — the watch returns to idle as soon as the submit
//  is accepted.
//

import Foundation
import Combine

/// ViewModel for the recording screen. Holds UI-facing state and coordinates
/// the `AudioRecordingService` (which wraps the `STTClient`). Contains no AVFoundation code.
@MainActor
final class RecordingViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var state: RecordingState = .idle
    /// Normalized audio level (0.0–1.0) for visualization. Smoothed for a natural feel.
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    /// Whether the server is configured (host + API key present).
    @Published private(set) var isConfigured: Bool = false

    // MARK: - Computed Properties

    var isRecording: Bool { state == .recording }
    var isSubmitting: Bool { state == .submitting }
    var isBusy: Bool { state == .submitting }

    /// Whether Cancel is available (recording only — once submitted, the
    /// backend owns the recording).
    var canCancel: Bool { state == .recording }

    // MARK: - Dependencies

    private let service: AudioRecordingService
    private let configStore: AppConfigStore
    private var levelMonitorTimer: AnyCancellable?
    private var recordingID: UUID?

    // MARK: - Init

    init(service: AudioRecordingService? = nil, configStore: AppConfigStore = .shared) {
        self.configStore = configStore
        self.service = service ?? AVAudioRecordingService(configStore: configStore)
        checkConfiguration()
    }

    // MARK: - Configuration

    /// Checks if the server is configured.
    func checkConfiguration() {
        isConfigured = configStore.load()?.isValid ?? false
    }

    /// Call this when config might have changed (e.g. synced from iPhone).
    func refreshConfiguration() {
        checkConfiguration()
    }

    // MARK: - Public API

    /// Starts recording and streaming. Requests microphone permission if needed.
    func startRecording() {
        guard state == .idle else { return }
        guard isConfigured else {
            errorMessage = AudioRecordingError.serverNotConfigured.localizedDescription
            return
        }

        Task {
            let granted = await service.requestPermission()
            guard granted else {
                errorMessage = AudioRecordingError.permissionDenied.localizedDescription
                return
            }

            do {
                let id = try await service.start()
                recordingID = id
                errorMessage = nil
                statusMessage = nil
                state = .recording
                startLevelMonitorTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Starts recording if the app is configured and idle.
    /// Used to auto-start on launch and when the config arrives from the iPhone.
    func startRecordingIfIdle() {
        guard state == .idle, isConfigured else { return }
        startRecording()
    }

    /// Cancels the recording: stops the audio engine and tells the backend
    /// to discard the spooled audio. Only available while recording.
    func cancelRecording() {
        guard state == .recording, let id = recordingID else { return }

        Task {
            // Stop the engine first so no further chunks are streamed,
            // then tell the backend to discard the recording.
            await service.stop()
            await service.cancel(recordingID: id)
            cleanup()
        }
    }

    /// Submits the recording: stops recording and hands the audio to the
    /// backend. Fire and forget — the backend transcribes and forwards the
    /// transcript to Hermes in the background; the watch returns to idle as
    /// soon as the backend accepts the audio (202).
    func submitRecording() {
        guard state == .recording else { return }
        guard let id = recordingID else { return }

        state = .submitting
        statusMessage = String(localized: "Sending…")
        stopLevelMonitorTimer()

        Task {
            // Stop recording (flushes remaining chunks, waits for uploads)
            await service.stop()

            do {
                // 202 = accepted. The backend now owns the recording.
                let deliveryTarget = configStore.load()?.deliveryTarget
                try await service.submit(recordingID: id, deliveryTarget: deliveryTarget)

                statusMessage = nil
                cleanup()
            } catch {
                statusMessage = nil
                errorMessage = error.localizedDescription
                cleanup()
            }
        }
    }

    // MARK: - Private

    private func cleanup() {
        stopLevelMonitorTimer()
        state = .idle
        audioLevel = 0
        recordingID = nil
        // Clear status after a brief delay so the user sees the final state
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if state == .idle {
                statusMessage = nil
            }
        }
    }

    private func stopLevelMonitorTimer() {
        levelMonitorTimer?.cancel()
        levelMonitorTimer = nil
    }

    /// Polls the service at 30 fps: updates the audio level for visualization
    /// and auto-submits when the user stops speaking.
    private func startLevelMonitorTimer() {
        levelMonitorTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                // Update audio level for visualization (scaled + smoothed).
                let rawRMS = self.service.currentRMS
                let scaled = min(rawRMS * 5.0, 1.0)
                self.audioLevel = self.audioLevel * 0.6 + scaled * 0.4

                // Auto-submit after sustained silence.
                if self.service.hasExceededSilenceThreshold {
                    self.submitRecording()
                }
            }
    }
}
