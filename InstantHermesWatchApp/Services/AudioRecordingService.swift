//
//  AudioRecordingService.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import AVFoundation

// MARK: - Errors

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case audioSessionConfigurationFailed(Error)
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied"
        case .audioSessionConfigurationFailed(let error):
            return "Failed to configure audio session: \(error.localizedDescription)"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}

// MARK: - Protocol

/// Abstracts audio recording and streaming, enabling testability and mocking.
protocol AudioRecordingService: AnyObject {
    /// Current raw RMS amplitude (thread-safe read). ~0.0–0.5 for speech.
    var currentRMS: Float { get }

    /// Whether silence has exceeded the threshold (thread-safe read).
    /// Only true after speech has been detected at least once.
    var hasExceededSilenceThreshold: Bool { get }

    /// Requests microphone permission.
    func requestPermission() async -> Bool

    /// Starts recording and streaming. Returns the recording session ID.
    /// Throws on audio session or engine failure.
    func start() throws -> UUID

    /// Stops recording immediately. Does not send any submit/cancel signal.
    func stop()

    /// Sends a submit signal so the server knows the recording is complete.
    func sendSubmitSignal(recordingID: UUID)

    /// Sends a cancel signal so the server knows the recording was discarded.
    func sendCancelSignal(recordingID: UUID)
}

// MARK: - Internal Helpers

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
    private var _currentRMS: Float = 0

    /// How long audio must stay below threshold before triggering.
    let silenceDuration: TimeInterval = 3.0

    /// RMS amplitude below this is considered silence (~ -40 dBFS).
    let amplitudeThreshold: Float = 0.01

    /// Latest RMS amplitude (raw, unscaled). Updated on the audio thread, read from the main actor.
    var currentRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _currentRMS
    }

    /// Whether silence has exceeded the threshold. Called from the main actor.
    var hasExceededSilenceThreshold: Bool {
        lock.lock()
        defer { lock.unlock() }

        guard hasDetectedSound else { return false }
        return CFAbsoluteTimeGetCurrent() - lastLoudTimestamp >= silenceDuration
    }

    /// Process an audio buffer. Called from the audio render thread.
    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.calculateRMS(buffer)

        lock.lock()
        defer { lock.unlock() }

        _currentRMS = rms
        if rms > amplitudeThreshold {
            lastLoudTimestamp = CFAbsoluteTimeGetCurrent()
            hasDetectedSound = true
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastLoudTimestamp = CFAbsoluteTimeGetCurrent()
        hasDetectedSound = false
        _currentRMS = 0
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

// MARK: - Implementation

/// Records microphone audio via `AVAudioEngine` and streams chunks to an HTTP endpoint.
final class AVAudioRecordingService: AudioRecordingService {
    private let audioEngine = AVAudioEngine()
    private let cancellationToken = CancellationToken()
    private let silenceDetector = SilenceDetector()

    // Dummy endpoint — replace with a real server when ready.
    private let endpointURL = URL(string: "http://localhost:8080/audio")!

    // MARK: AudioRecordingService

    var currentRMS: Float { silenceDetector.currentRMS }

    var hasExceededSilenceThreshold: Bool { silenceDetector.hasExceededSilenceThreshold }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws -> UUID {
        cancellationToken.reset()
        silenceDetector.reset()
        let recordingID = UUID()

        // Configure the audio session for recording.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            throw AudioRecordingError.audioSessionConfigurationFailed(error)
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Capture only Sendable values so the tap callback can run on the audio thread.
        let token = cancellationToken
        let detector = silenceDetector
        let url = endpointURL

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard !token.isCancelled else { return }
            detector.processBuffer(buffer)
            Self.sendChunk(buffer: buffer, to: url, recordingID: recordingID)
        }

        do {
            try audioEngine.start()
        } catch {
            throw AudioRecordingError.engineStartFailed(error)
        }

        return recordingID
    }

    func stop() {
        cancellationToken.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func sendSubmitSignal(recordingID: UUID) {
        sendActionSignal(recordingID: recordingID, action: "submit")
    }

    func sendCancelSignal(recordingID: UUID) {
        sendActionSignal(recordingID: recordingID, action: "cancel")
    }

    // MARK: Private

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
    private static func sendChunk(buffer: AVAudioPCMBuffer, to url: URL, recordingID: UUID) {
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
