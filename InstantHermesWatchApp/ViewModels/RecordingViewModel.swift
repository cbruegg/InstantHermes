//
//  RecordingViewModel.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import Combine

/// ViewModel for the recording screen. Holds UI-facing state and coordinates
/// the `AudioRecordingService`. Contains no AVFoundation or networking code.
@MainActor
final class RecordingViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var state: RecordingState = .idle
    /// Normalized audio level (0.0–1.0) for visualization. Smoothed for a natural feel.
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?

    // MARK: - Computed Properties

    var isRecording: Bool { state == .recording }

    // MARK: - Dependencies

    private let service: AudioRecordingService
    private var levelMonitorTimer: AnyCancellable?
    private var recordingID: UUID?

    // MARK: - Init

    init(service: AudioRecordingService? = nil) {
        self.service = service ?? AVAudioRecordingService()
    }

    // MARK: - Public API

    /// Starts recording and streaming. Requests microphone permission if needed.
    func startRecording() {
        guard !isRecording else { return }

        Task {
            let granted = await service.requestPermission()
            guard granted else {
                errorMessage = AudioRecordingError.permissionDenied.localizedDescription
                return
            }

            do {
                let id = try service.start()
                recordingID = id
                errorMessage = nil
                state = .recording
                startLevelMonitorTimer()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancels recording — stops without submitting. Sends a cancel signal to the endpoint.
    func cancelRecording() {
        guard isRecording else { return }
        let id = recordingID
        cleanup()
        if let id {
            service.sendCancelSignal(recordingID: id)
        }
    }

    /// Submits recording — stops and sends a submit signal so the server knows the audio is complete.
    func submitRecording() {
        guard isRecording else { return }
        let id = recordingID
        cleanup()
        if let id {
            service.sendSubmitSignal(recordingID: id)
        }
    }

    // MARK: - Private

    private func cleanup() {
        service.stop()
        levelMonitorTimer?.cancel()
        levelMonitorTimer = nil
        state = .idle
        audioLevel = 0
        recordingID = nil
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
