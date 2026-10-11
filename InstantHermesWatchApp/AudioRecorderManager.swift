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

/// Records microphone audio and streams each chunk to an HTTP endpoint.
@MainActor
final class AudioRecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let cancellationToken = CancellationToken()

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

    /// Stops recording and streaming. Can be followed by `startRecording()` to restart.
    func stopRecording() {
        guard isRecording else { return }
        cancellationToken.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Convenience: stop then start again.
    func restartRecording() {
        stopRecording()
        startRecording()
    }

    // MARK: - Private

    private func beginRecording() {
        cancellationToken.reset()
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard !token.isCancelled else { return }
            Self.sendChunk(buffer: buffer, to: url)
        }

        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
        }
    }

    /// Converts an audio buffer to raw float data and POSTs it to the endpoint.
    /// Runs on the audio render thread — keep it lightweight.
    private nonisolated static func sendChunk(buffer: AVAudioPCMBuffer, to url: URL) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let byteCount = frameCount * MemoryLayout<Float>.stride
        let data = Data(bytes: channelData[0], count: byteCount)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("float32", forHTTPHeaderField: "X-Audio-Format")
        request.setValue("\(buffer.format.sampleRate)", forHTTPHeaderField: "X-Sample-Rate")
        request.httpBody = data

        // Fire-and-forget; errors are expected with a dummy endpoint.
        URLSession.shared.dataTask(with: request).resume()
    }
}
