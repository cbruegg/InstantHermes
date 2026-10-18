//
//  RecordingViewModel.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  ViewModel for the recording screen. Implements the full state machine:
//  idle → recording → submitting → idle, with Cancel available while recording.
//  Fire and forget: the STT backend transcribes the audio and forwards the
//  transcript to Hermes — the device returns to idle as soon as the submit
//  is accepted.
//
//  Created by Christian Brüggemann on 11.10.26.
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

    /// Whether Cancel is available. Cancel is available during recording AND
    /// during submitting (while the submit POST is in flight, or after 202
    /// while the backend is processing). Once cancelled, the backend aborts
    /// transcription and will not submit to Hermes.
    var canCancel: Bool { state == .recording || state == .submitting }

    // MARK: - Dependencies

    private let service: AudioRecordingService
    private let configStore: AppConfigStore
    private var levelMonitorTimer: AnyCancellable?
    private var recordingID: UUID?
    /// Set synchronously when `startRecording()` begins, before any `await`.
    /// Prevents concurrent calls (e.g. `onAppear` + `onChange(of: scenePhase)`
    /// both firing on launch) from reaching `installTap` twice.
    private var isStarting = false
    /// The in-flight submit task. Stored so cancel can interrupt it before
    /// the submit POST is sent (e.g. user taps Cancel while chunks are
    /// still being flushed).
    private var submitTask: Task<Void, Never>?

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

    /// Call this when config might have changed (e.g. synced from iPhone,
    /// or edited in the settings tab on iOS).
    func refreshConfiguration() {
        checkConfiguration()
    }

    // MARK: - Public API

    /// Starts recording and streaming. Requests microphone permission if needed.
    func startRecording() {
        // Always re-check config — the user may have changed settings
        // while this view model was alive (e.g. on the iOS Settings tab).
        refreshConfiguration()
        // Guard synchronously — state is only set to .recording after the
        // async start completes, so without this flag, two rapid calls
        // (e.g. onAppear + scenePhase change) would both pass the check
        // and double-install the audio tap.
        guard state == .idle, !isStarting else { return }
        guard isConfigured else {
            errorMessage = AudioRecordingError.serverNotConfigured.localizedDescription
            return
        }

        isStarting = true

        Task {
            let granted = await service.requestPermission()
            guard granted else {
                isStarting = false
                errorMessage = AudioRecordingError.permissionDenied.localizedDescription
                return
            }

            do {
                let id = try await service.start()
                recordingID = id
                errorMessage = nil
                statusMessage = nil
                state = .recording
                isStarting = false
                startLevelMonitorTimer()
            } catch {
                isStarting = false
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
    /// to discard the spooled audio. Available during recording AND submitting.
    ///
    /// - During `.recording`: stops the engine, discards spooled chunks on the
    ///   backend. The backend never starts transcription.
    /// - During `.submitting`: interrupts the in-flight submit task (if the
    ///   submit POST hasn't been sent yet) and sends a cancel action to the
    ///   backend. If the backend already accepted (202), the cancel signals
    ///   the background worker to abort before transcription and before the
    ///   Hermes POST.
    func cancelRecording() {
        guard state == .recording || state == .submitting, let id = recordingID else { return }

        // Interrupt the submit task — prevents the submit POST from being sent
        // if it hasn't gone out yet. If it's already in flight (or accepted),
        // the cancel action below handles it.
        submitTask?.cancel()
        submitTask = nil

        // Reset the UI state synchronously — cancel is local-first. The engine
        // stop and the best-effort backend cancel continue in the background
        // and must not block the state machine: when the backend is
        // unreachable the upload queue cannot drain, and waiting for it left
        // the app stuck on the recording screen with a Cancel button that
        // appeared dead.
        cleanup()

        Task {
            // Stops the engine, drops pending uploads, and tells the backend
            // to discard the recording (best-effort).
            await service.cancel(recordingID: id)
        }
    }

    /// Submits the recording: stops recording and hands the audio to the
    /// backend. Fire and forget — the backend transcribes and forwards the
    /// transcript to Hermes in the background; the device returns to idle as
    /// soon as the backend accepts the audio (202).
    func submitRecording() {
        guard state == .recording else { return }
        guard let id = recordingID else { return }

        state = .submitting
        statusMessage = String(localized: "Sending…")
        stopLevelMonitorTimer()

        submitTask = Task {
            // Stop recording (flushes remaining chunks, waits for uploads)
            await service.stop()

            // If the user tapped Cancel while we were flushing, don't send submit.
            guard !Task.isCancelled else { return }

            do {
                // 202 = accepted. The backend now owns the recording.
                let deliveryTarget = configStore.load()?.deliveryTarget
                try await service.submit(recordingID: id, deliveryTarget: deliveryTarget)

                await MainActor.run {
                    statusMessage = nil
                    cleanup()
                }
            } catch {
                await MainActor.run {
                    statusMessage = nil
                    // A cancelled submit (the user tapped Cancel while the POST
                    // was in flight) is not an error — the cancel path already
                    // reset the UI.
                    if !Task.isCancelled {
                        errorMessage = error.localizedDescription
                    }
                    cleanup()
                }
            }
        }
    }

    // MARK: - Private

    private func cleanup() {
        stopLevelMonitorTimer()
        submitTask = nil
        isStarting = false
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

    /// Polls the service at 30 fps: stops on permanent upload failure,
    /// updates the audio level for visualization, and auto-submits when the
    /// user stops speaking.
    private func startLevelMonitorTimer() {
        levelMonitorTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                // Stop immediately when an upload has permanently failed
                // (e.g. the backend is unreachable) — otherwise the user
                // records into the void until the silence auto-submit fires
                // and fails.
                if self.service.hasUploadError {
                    self.handleConnectionLost()
                    return
                }

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

    /// Stops recording because a chunk upload permanently failed (the backend
    /// is unreachable). Discards the recording (best-effort backend cancel)
    /// and shows an error instead of recording into the void.
    private func handleConnectionLost() {
        guard state == .recording else { return }
        errorMessage = String(localized: "Connection lost — couldn't reach the server")
        cancelRecording()
    }
}
