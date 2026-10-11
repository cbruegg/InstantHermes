//
//  RecordingViewModel.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//
//  ViewModel for the recording screen. Implements the full state machine:
//  idle → recording → transcribing → submitting → idle
//  with Cancel available in recording and transcribing states.
//

import Foundation
import Combine

/// ViewModel for the recording screen. Holds UI-facing state and coordinates
/// the `AudioRecordingService` and `HermesClient`. Contains no AVFoundation code.
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
    var isTranscribing: Bool { state == .transcribing }
    var isSubmitting: Bool { state == .submitting }
    var isBusy: Bool { state == .transcribing || state == .submitting }

    /// Whether Cancel is available (recording or transcribing).
    var canCancel: Bool { state == .recording || state == .transcribing }

    // MARK: - Dependencies

    private let service: AudioRecordingService
    private let configStore: AppConfigStore
    private var hermesClient: HermesClient?
    private var levelMonitorTimer: AnyCancellable?
    private var recordingID: UUID?

    // MARK: - Init

    init(service: AudioRecordingService? = nil, configStore: AppConfigStore = .shared) {
        self.configStore = configStore
        self.service = service ?? AVAudioRecordingService(configStore: configStore)
        checkConfiguration()
    }

    // MARK: - Configuration

    /// Checks if the server is configured and creates the Hermes client.
    func checkConfiguration() {
        if let config = configStore.load(), config.isValid {
            isConfigured = true
            hermesClient = HermesClient(config: config)
        } else {
            isConfigured = false
            hermesClient = nil
        }
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

    /// Cancels the current operation.
    /// - In `recording`: stops recording, sends cancel to STT backend.
    /// - In `transcribing`: discards the transcript when it arrives (never submits to Hermes).
    func cancelRecording() {
        guard canCancel else { return }

        let wasTranscribing = (state == .transcribing)
        let id = recordingID

        // If we were transcribing, we need to handle the in-flight submit.
        // The submit task will check a cancellation flag and discard the result.
        if wasTranscribing {
            cancelRequested = true
        }

        Task {
            if let id, state == .recording {
                await service.cancel(recordingID: id)
            }
            cleanup()
        }
    }

    /// Submits the recording: stops recording, requests transcription,
    /// then submits the transcript to Hermes.
    func submitRecording() {
        guard state == .recording else { return }
        guard let id = recordingID else { return }
        guard let hermes = hermesClient else {
            errorMessage = HermesClientError.notConfigured.localizedDescription
            return
        }

        cancelRequested = false
        state = .transcribing
        statusMessage = String(localized: "Transcribing…")
        stopLevelMonitorTimer()

        Task {
            // Stop recording (flushes remaining chunks, waits for uploads)
            await service.stop()

            // Request transcription from STT backend
            do {
                let transcript = try await service.submit(recordingID: id)

                // Check if user cancelled during transcription
                guard !cancelRequested else {
                    // Discard transcript — never submit to Hermes
                    await service.cancel(recordingID: id)
                    cleanup()
                    return
                }

                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    statusMessage = nil
                    errorMessage = String(localized: "Didn't catch that")
                    cleanup()
                    return
                }

                // Submit to Hermes (with delivery instruction if configured)
                state = .submitting
                statusMessage = String(localized: "Sending…")

                let deliveryInstruction = configStore.load()?.deliveryInstruction
                _ = try await hermes.submitMessage(
                    text: trimmed,
                    idempotencyKey: id,
                    deliveryInstruction: deliveryInstruction
                )

                // Fire-and-forget: 202 means Hermes accepted it
                statusMessage = nil
                cleanup()

            } catch {
                // If cancelled during transcription, the error might be from the
                // cancelled submit — just clean up silently.
                if cancelRequested {
                    cleanup()
                    return
                }
                statusMessage = nil
                errorMessage = error.localizedDescription
                cleanup()
            }
        }
    }

    // MARK: - Private

    /// Set to true when the user cancels during transcription.
    /// The in-flight submit task checks this and discards the transcript.
    private var cancelRequested = false

    private func cleanup() {
        stopLevelMonitorTimer()
        state = .idle
        audioLevel = 0
        recordingID = nil
        cancelRequested = false
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
