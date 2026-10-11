//
//  AudioRecorderManager.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import AVFoundation
import Combine

/// Thread-safe flag used to signal cancellation from the audio tap callback.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = false
    }
}

/// Detects silence by tracking RMS amplitude over time.
/// Only triggers after speech has been detected at least once,
/// so initial silence at recording start does not cause a stop.
final class SilenceDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLoudTimestamp: CFAbsoluteTime = 0
    private var hasDetectedSound = false

    /// How long audio must stay below threshold before triggering.
    let silenceDuration: TimeInterval = 3.0

    /// RMS amplitude below this is considered silence (~ -40 dBFS).
    let amplitudeThreshold: Float = 0.01

    /// Process an audio buffer. Called from the audio render thread.
    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.calculateRMS(buffer)
        guard rms > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        if rms > amplitudeThreshold {
            lastLoudTimestamp = CFAbsoluteTimeGetCurrent()
            hasDetectedSound = true
        }
    }

    /// Whether silence has exceeded the threshold. Called from the main actor.
    var hasExceededSilenceThreshold: Bool {
        lock.lock()
        defer { lock.unlock() }

        guard hasDetectedSound else { return false }
        return CFAbsoluteTimeGetCurrent() - lastLoudTimestamp >= silenceDuration
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastLoudTimestamp = CFAbsoluteTimeGetCurrent()
        hasDetectedSound = false
    }

    /// RMS (root mean square) amplitude of a PCM buffer — a good proxy for perceived loudness.
    private static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frameCount))
    }
}

/// Records microphone audio and streams each chunk to an HTTP endpoint.
@MainActor
final class AudioRecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let cancellationToken = CancellationToken()
    private let silenceDetector = SilenceDetector()
    private var silenceCheckTimer: AnyCancellable?
    private var recordingID: UUID?

    // Dummy endpoint — replace with a real server when ready.
    private let endpointURL = URL(string: "http://localhost:8080/audio")!

    // MARK: - Public API

    /// Starts recording and streaming. Requests microphone permission if needed.
    func startRecording() {
        guard !isRecording else { return }

        Task {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                errorMessage = "Microphone permission denied"
                return
            }
            beginRecording()
        }
    }

    /// Cancels recording — stops without submitting. Sends a cancel signal to the endpoint.
    func stopRecording() {
        guard isRecording else { return }
        let id = recordingID
        cleanup()
        if let id {
            sendActionSignal(recordingID: id, action: "cancel")
        }
    }

    /// Submits recording — stops and sends a submit signal so the server knows the audio is complete.
    func submitRecording() {
        guard isRecording else { return }
        let id = recordingID
        cleanup()
        if let id {
            sendActionSignal(recordingID: id, action: "submit")
        }
    }

    /// Convenience: cancel then start again.
    func restartRecording() {
        stopRecording()
        startRecording()
    }

    // MARK: - Private

    private func beginRecording() {
        cancellationToken.reset()
        silenceDetector.reset()
        recordingID = UUID()
        errorMessage = nil

        // Configure the audio session for recording.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            errorMessage = "Failed to configure audio session: \(error.localizedDescription)"
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Capture only Sendable values so the tap callback can run on the audio thread.
        let token = cancellationToken
        let url = endpointURL
        let detector = silenceDetector
        let recID = recordingID!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard !token.isCancelled else { return }
            detector.processBuffer(buffer)
            Self.sendChunk(buffer: buffer, to: url, recordingID: recID)
        }

        do {
            try audioEngine.start()
            isRecording = true
            startSilenceCheckTimer()
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
        }
    }

    private func cleanup() {
        cancellationToken.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        silenceCheckTimer?.cancel()
        silenceCheckTimer = nil
        isRecording = false
        recordingID = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Polls the silence detector and auto-submits when the user stops speaking.
    private func startSilenceCheckTimer() {
        silenceCheckTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.silenceDetector.hasExceededSilenceThreshold else { return }
                self.submitRecording()
            }
    }

    /// Sends a submit/cancel signal so the server knows the recording's final status.
    private func sendActionSignal(recordingID: UUID, action: String) {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(action, forHTTPHeaderField: "X-Action")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Converts an audio buffer to raw float data and POSTs it to the endpoint.
    /// Runs on the audio render thread — keep it lightweight.
    private nonisolated static func sendChunk(buffer: AVAudioPCMBuffer, to url: URL, recordingID: UUID) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let byteCount = frameCount * MemoryLayout<Float>.stride
        let data = Data(bytes: channelData[0], count: byteCount)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("float32", forHTTPHeaderField: "X-Audio-Format")
        request.setValue("\(buffer.format.sampleRate)", forHTTPHeaderField: "X-Sample-Rate")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.httpBody = data

        // Fire-and-forget; errors are expected with a dummy endpoint.
        URLSession.shared.dataTask(with: request).resume()
    }
}
