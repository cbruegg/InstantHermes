//
//  AudioRecordingService.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  Records microphone audio via AVAudioEngine, converts to 16 kHz mono PCM
//  via AVAudioConverter (sample rate conversion), batches chunks, and streams
//  them to the STT backend via STTClient. The backend wraps PCM in WAV for
//  Voxtral transcription.
//
//  Note: AAC encoding via AVAudioConverter requires AudioToolbox, which is not
//  available on watchOS. PCM streaming is the documented fallback (PLAN.md §5):
//  ~64 KB/s over the tailnet is trivial bandwidth.
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Errors

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case audioSessionConfigurationFailed(Error)
    case engineStartFailed(Error)
    case converterCreationFailed
    case serverNotConfigured
    case uploadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Microphone permission denied")
        case .audioSessionConfigurationFailed(let error):
            return String(format: String(localized: "Failed to configure audio session: %@"), error.localizedDescription)
        case .engineStartFailed(let error):
            return String(format: String(localized: "Failed to start audio engine: %@"), error.localizedDescription)
        case .converterCreationFailed:
            return String(localized: "Failed to create audio converter")
        case .serverNotConfigured:
            return String(localized: "Server not configured. Open the app settings to set up the server.")
        case .uploadFailed(let error):
            return String(format: String(localized: "Audio upload failed: %@"), error.localizedDescription)
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

    /// Whether a chunk upload has permanently failed (all retries exhausted,
    /// e.g. the backend is unreachable). Thread-safe read for the view model's
    /// level timer; while true the recording is void.
    var hasUploadError: Bool { get }

    /// Requests microphone permission.
    func requestPermission() async -> Bool

    /// Starts recording and streaming. Returns the recording session ID.
    /// Throws on audio session, engine, or configuration failure.
    func start() async throws -> UUID

    /// Stops recording immediately. Flushes any pending batched chunks and
    /// waits (bounded) for in-flight uploads so a following submit sees a
    /// consistent queue. Does not send any submit/cancel signal. Also stops
    /// any active keepalive timer.
    func stop() async

    /// Submits the recording to the backend. Fire and forget: returns once the
    /// backend has accepted the audio (202); transcription, the Hermes
    /// submission, and response delivery happen server-side.
    /// Throws on upload/acceptance failure.
    /// After 202, starts a keepalive timer that pings the backend periodically
    /// so the backend can detect client disconnection and abort processing.
    func submit(recordingID: UUID, deliveryTarget: String?) async throws

    /// Cancels the recording: stops the audio engine, drops pending chunk
    /// uploads, and tells the backend to discard spooled chunks (best-effort;
    /// safe when the backend is unreachable). If the recording is already
    /// being processed (after 202), signals the backend to abort before
    /// submitting to Hermes.
    func cancel(recordingID: UUID) async
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

/// Thread-safe holder for the latest chunk-upload error. Set from the
/// batcher's upload tasks and read synchronously from the view model's
/// level timer (which polls at 30 fps and cannot await an actor).
/// Members are nonisolated (the project defaults to MainActor isolation)
/// because the flag is thread-safe via its lock and called from the
/// batcher actor, the audio tap, and the main actor alike.
final class UploadErrorFlag: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    // nonisolated(unsafe): mutable stored properties need the unsafe spelling
    // outside Swift 6 mode; access is serialized through `lock`.
    private nonisolated(unsafe) var _error: Error?

    nonisolated var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _error != nil
    }

    nonisolated func set(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        _error = error
    }

    nonisolated func getAndClear() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let error = _error
        _error = nil
        return error
    }

    nonisolated func reset() {
        lock.lock()
        defer { lock.unlock() }
        _error = nil
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

/// Batches PCM audio data and flushes it as one chunk upload per ~1 s
/// (~64 KB of 16 kHz float32 mono). Large chunks keep the serial upload
/// queue from falling behind: the device→Pi path (Bluetooth/WiFi hop plus
/// tailnet) has enough per-request RTT that small ~4 KB chunks made the
/// backlog drain — and "Sending…" block — at submit time.
/// Runs uploads on a serial queue so sequences stay contiguous.
actor ChunkBatcher {
    private var buffer = Data()
    private var lastFlushTime = Date()
    private let flushInterval: TimeInterval = 1.0
    private let flushSizeThreshold: Int = 65536

    private let recordingID: UUID
    private let sttClient: STTClient
    private let errorFlag: UploadErrorFlag
    private var sequence: Int = 0

    /// Serial queue for uploads — ensures chunks are sent in order.
    private var serialQueue: [SerialUpload] = []
    private var isProcessing = false

    private struct SerialUpload {
        let sequence: Int
        let data: Data
    }

    init(recordingID: UUID, sttClient: STTClient, errorFlag: UploadErrorFlag) {
        self.recordingID = recordingID
        self.sttClient = sttClient
        self.errorFlag = errorFlag
    }

    /// Adds PCM audio data to the batch buffer.
    /// Flushes (enqueues an upload) when thresholds are met.
    func add(_ data: Data) {
        buffer.append(data)
        let now = Date()
        if buffer.count >= flushSizeThreshold || now.timeIntervalSince(lastFlushTime) >= flushInterval {
            flush(now: now)
        }
    }

    /// Flushes any remaining buffered data. Call when recording stops.
    func flushAll() {
        guard !buffer.isEmpty else { return }
        flush(now: Date())
    }

    /// Waits for all in-flight uploads to complete.
    /// - Parameter timeout: Maximum time to wait. When the backend is
    ///   unreachable, each queued chunk can take tens of seconds to exhaust
    ///   its retries, so the wait is bounded; the caller then proceeds to a
    ///   clear upload error instead of hanging on a queue that cannot drain.
    /// - Note: Returns as soon as the calling task is cancelled — a cancelled
    ///   caller must not wait (or spin) until the queue drains.
    func waitForUploads(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && (isProcessing || !serialQueue.isEmpty) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    /// Drops all queued (not yet started) uploads; the in-flight upload, if
    /// any, finishes in the background. Used when cancelling: the backend is
    /// told to discard the recording, so uploading the remaining chunks is
    /// pointless — and during an outage the queue cannot drain anyway.
    func cancelPendingUploads() {
        serialQueue.removeAll()
    }

    /// Returns any upload error that occurred, then clears it.
    func getAndClearError() -> Error? {
        errorFlag.getAndClear()
    }

    private func flush(now: Date) {
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer = Data()
        lastFlushTime = now

        let seq = sequence
        sequence += 1

        serialQueue.append(SerialUpload(sequence: seq, data: chunk))
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard !isProcessing, !serialQueue.isEmpty else { return }
        isProcessing = true

        let upload = serialQueue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            await self.uploadWithRetry(upload)
            await self.markComplete()
        }
    }

    private func uploadWithRetry(_ upload: SerialUpload) async {
        let maxRetries = 3
        var lastError: Error?

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                // Exponential backoff: 0.5s, 1s, 2s
                let delay = pow(2.0, Double(attempt - 1)) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                try await sttClient.uploadChunk(
                    recordingID: recordingID,
                    sequence: upload.sequence,
                    data: upload.data
                )
                return // success
            } catch {
                lastError = error
            }
        }

        // All retries failed — sequences would have a gap; the backend would 409 anyway.
        if let error = lastError {
            errorFlag.set(error)
        }
    }

    private func markComplete() {
        isProcessing = false
        processQueueIfNeeded()
    }
}

// MARK: - Implementation

/// Records microphone audio via `AVAudioEngine`, converts to 16 kHz mono PCM,
/// and streams batched chunks to the STT backend.
final class AVAudioRecordingService: AudioRecordingService, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let cancellationToken = CancellationToken()
    private let silenceDetector = SilenceDetector()
    /// Latest chunk-upload error, shared with the batcher and readable
    /// synchronously by the view model's level timer.
    private let uploadErrorFlag = UploadErrorFlag()

    private let configStore: AppConfigStore
    private var sttClient: STTClient?
    private var batcher: ChunkBatcher?
    private var converter: AVAudioConverter?
    /// In-flight engine teardown from cancel(). The view model resets to
    /// idle immediately on cancel, so a new recording can be started while
    /// the previous teardown is still running — start() awaits this task
    /// before reconfiguring the engine.
    private var teardownTask: Task<Void, Never>?

    // MARK: Keepalive

    /// How often to send keepalive pings after submit (202).
    private static let keepaliveInterval: TimeInterval = 5.0
    /// How long to keep sending keepalives after submit (covers transcription +
    /// Hermes submission time; the backend polls for up to 300s but the
    /// critical gate is before the Hermes POST, which happens within ~60s).
    private static let keepaliveDuration: TimeInterval = 90.0

    /// Task that sends periodic keepalives. Cancelled on stop() or new recording.
    private var keepaliveTask: Task<Void, Never>?

    /// Target PCM format: 16 kHz, mono, float32 (for Voxtral compatibility).
    private static let targetSampleRate: Double = 16000
    private static let targetChannelCount: AVAudioChannelCount = 1

    init(configStore: AppConfigStore = .shared) {
        self.configStore = configStore
    }

    // MARK: AudioRecordingService

    var currentRMS: Float { silenceDetector.currentRMS }

    var hasExceededSilenceThreshold: Bool { silenceDetector.hasExceededSilenceThreshold }

    var hasUploadError: Bool { uploadErrorFlag.hasError }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async throws -> UUID {
        // A cancelled recording tears down in the background (the view model
        // resets to idle immediately), so a new recording can be started
        // while the previous engine stop is still running — wait for it.
        await teardownTask?.value
        teardownTask = nil

        // Cancel any existing keepalive from a previous recording
        keepaliveTask?.cancel()
        keepaliveTask = nil
        uploadErrorFlag.reset()

        // Load config and create STT client
        guard let config = configStore.load(), config.isValid else {
            throw AudioRecordingError.serverNotConfigured
        }
        guard let client = STTClient(config: config) else {
            throw AudioRecordingError.serverNotConfigured
        }

        cancellationToken.reset()
        silenceDetector.reset()
        let recordingID = UUID()

        // Configure the audio session on a background queue — setActive can block
        // the calling thread, and we must not block the main actor (watchdog timeout).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioRecordingError.engineStartFailed(NSError(domain: "AVAudioRecordingService", code: -1)))
                    return
                }

                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .default)
                    try session.setActive(true)
                } catch {
                    continuation.resume(throwing: AudioRecordingError.audioSessionConfigurationFailed(error))
                    return
                }

                let inputNode = self.audioEngine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)

                // Create target PCM format: 16 kHz, mono, float32
                guard let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Self.targetSampleRate,
                    channels: Self.targetChannelCount,
                    interleaved: false
                ) else {
                    continuation.resume(throwing: AudioRecordingError.converterCreationFailed)
                    return
                }

                // Create converter: hardware PCM → 16 kHz mono PCM
                guard let pcmConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    continuation.resume(throwing: AudioRecordingError.converterCreationFailed)
                    return
                }
                self.converter = pcmConverter

                // Create the chunk batcher
                let newBatcher = ChunkBatcher(recordingID: recordingID, sttClient: client, errorFlag: uploadErrorFlag)
                self.batcher = newBatcher
                self.sttClient = client

                // Capture Sendable values for the tap callback
                let token = self.cancellationToken
                let detector = self.silenceDetector
                let conv = pcmConverter
                let batch = newBatcher

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                    guard !token.isCancelled else { return }
                    detector.processBuffer(buffer)

                    // Convert PCM to 16 kHz mono and enqueue
                    Self.convertAndEnqueue(buffer: buffer, converter: conv, batcher: batch)
                }

                do {
                    try self.audioEngine.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: AudioRecordingError.engineStartFailed(error))
                }
            }
        }

        return recordingID
    }

    func stop() async {
        cancellationToken.cancel()
        keepaliveTask?.cancel()
        keepaliveTask = nil

        await stopEngine()

        // Flush remaining batched chunks and wait for in-flight uploads so
        // the following submit sees a consistent queue. Bounded: when the
        // backend is unreachable, each chunk can take tens of seconds to
        // exhaust its retries.
        await batcher?.flushAll()
        await batcher?.waitForUploads(timeout: 30)
    }

    /// Stops the audio engine, removes the input tap, and deactivates the
    /// audio session. Engine/session calls can block, so they run on a
    /// background queue while the caller is suspended.
    private func stopEngine() async {
        // Stop audio engine on a background queue — stop() can block.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.audioEngine.stop()
                self?.audioEngine.inputNode.removeTap(onBus: 0)
                continuation.resume()
            }
        }

        // Deactivate audio session on background queue — setActive can block.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                continuation.resume()
            }
        }
    }

    func submit(recordingID: UUID, deliveryTarget: String? = nil) async throws {
        // Check for upload errors first
        if let error = await batcher?.getAndClearError() {
            throw AudioRecordingError.uploadFailed(error)
        }

        guard let client = sttClient else {
            throw AudioRecordingError.serverNotConfigured
        }

        try await client.submit(recordingID: recordingID, deliveryTarget: deliveryTarget)

        // 202 accepted — start keepalive timer so the backend can detect
        // if this client disconnects during processing.
        startKeepalive(recordingID: recordingID, client: client)
    }

    func cancel(recordingID: UUID) async {
        // Stop keepalives — we're cancelling, no need to signal liveness.
        keepaliveTask?.cancel()
        keepaliveTask = nil
        // Stop the tap so no further chunks are produced.
        cancellationToken.cancel()

        // Capture the current client/batcher: start() may replace them while
        // this teardown runs in the background (the view model resets to idle
        // immediately on cancel, so a new recording can begin before the old
        // engine stop finishes).
        let client = sttClient
        let batcher = self.batcher

        let task = Task { [weak self] in
            guard let self else { return }
            await self.stopEngine()
            // Drop queued uploads — the backend is told to discard the
            // recording, so uploading the remaining chunks is pointless
            // (and during an outage the queue cannot drain anyway).
            await batcher?.cancelPendingUploads()
            // Best-effort cancel — safe to call when the backend is unreachable.
            try? await client?.cancel(recordingID: recordingID)
        }
        teardownTask = task
        await task.value
    }

    // MARK: Keepalive

    /// Starts a background task that sends keepalive pings to the backend
    /// every `keepaliveInterval` seconds for `keepaliveDuration` seconds.
    /// The backend uses these to detect client disconnection and abort
    /// processing before submitting to Hermes.
    private func startKeepalive(recordingID: UUID, client: STTClient) {
        keepaliveTask?.cancel()

        let interval = Self.keepaliveInterval
        let duration = Self.keepaliveDuration

        keepaliveTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(duration)
            while !Task.isCancelled && Date() < deadline {
                // Send keepalive (best-effort)
                await client.keepalive(recordingID: recordingID)

                // Sleep until next beat, or exit early if cancelled
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            await MainActor.run { self?.keepaliveTask = nil }
        }
    }

    // MARK: Private

    /// Converts a PCM buffer to 16 kHz mono float32 and enqueues the raw bytes.
    /// Runs on the audio render thread — must be fast and non-blocking.
    private static func convertAndEnqueue(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        batcher: ChunkBatcher
    ) {
        // Calculate output frame count based on sample rate ratio
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = Self.targetSampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else { return }

        // Extract float32 samples as Data
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0,
              let channelData = outputBuffer.floatChannelData else { return }

        let byteCount = frameLength * MemoryLayout<Float>.stride
        let data = Data(bytes: channelData[0], count: byteCount)

        // Enqueue on the batcher (actor-isolated, thread-safe)
        Task {
            await batcher.add(data)
        }
    }
}
