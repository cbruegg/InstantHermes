//
//  STTClient.swift
//  InstantHermesWatchApp
//
//  HTTP client for the instanthermes-stt backend (:8643).
//  Handles chunk uploads, submit (fire and forget: the backend transcribes
//  and forwards to Hermes), and cancel actions.
//

import Foundation

// MARK: - Errors

enum STTClientError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(Int, String)
    case audioIncomplete(missing: [Int])
    case sttUnavailable(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured. Set up the server in the iPhone app."
        case .invalidResponse:
            return "Invalid response from STT server"
        case .serverError(let code, let message):
            return "STT server error (\(code)): \(message)"
        case .audioIncomplete(let missing):
            return "Audio incomplete — missing \(missing.count) chunk(s)"
        case .sttUnavailable(let message):
            return "Transcription unavailable: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Response types

struct ErrorResponse: Decodable {
    let error: String
    let missing: [Int]?
    let message: String?
}

// MARK: - STT Client

/// Client for the instanthermes-stt backend.
/// All requests carry `Authorization: Bearer <apiKey>`.
final class STTClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init?(config: ServerConfig) {
        guard let url = config.sttBaseURL, !config.apiKey.isEmpty else {
            return nil
        }
        self.baseURL = url
        self.apiKey = config.apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10 // chunks: 10s
        config.timeoutIntervalForResource = 30 // generous ceiling; submit returns as soon as the backend accepts (202)
        self.session = URLSession(configuration: config)
    }

    // MARK: Chunk Upload

    /// Uploads a single audio chunk.
    /// - Parameters:
    ///   - recordingID: The recording session UUID.
    ///   - sequence: 0-based contiguous chunk sequence number.
    ///   - data: Raw PCM float32 bytes (16 kHz, mono).
    func uploadChunk(recordingID: UUID, sequence: Int, data: Data) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.setValue("\(sequence)", forHTTPHeaderField: "X-Chunk-Sequence")
        request.setValue("pcm-float32", forHTTPHeaderField: "X-Audio-Format")
        request.setValue("16000", forHTTPHeaderField: "X-Sample-Rate")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw STTClientError.serverError(httpResponse.statusCode, "chunk upload failed")
        }
    }

    // MARK: Actions

    /// Submits a recording to the backend. Fire and forget: returns as soon
    /// as the backend accepts the audio (202). The backend then transcribes
    /// it (Voxtral), forwards the transcript to Hermes, and — if a delivery
    /// target is set — delivers the response to that platform's home channel.
    /// - Parameters:
    ///   - recordingID: The recording session UUID (the backend uses it as the
    ///     Hermes idempotency key).
    ///   - deliveryTarget: Where the backend should deliver the Hermes response
    ///     (e.g. "matrix"), or nil/empty for no delivery.
    func submit(recordingID: UUID, deliveryTarget: String? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.setValue("submit", forHTTPHeaderField: "X-Action")
        if let target = deliveryTarget, !target.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["delivery_target": target])
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 202:
            return // accepted — the backend processes the recording in the background
        case 409:
            let err = (try? JSONDecoder().decode(ErrorResponse.self, from: data))
                ?? ErrorResponse(error: "audio_incomplete", missing: nil, message: nil)
            throw STTClientError.audioIncomplete(missing: err.missing ?? [])
        case 503:
            let err = (try? JSONDecoder().decode(ErrorResponse.self, from: data))
                ?? ErrorResponse(error: "stt_unavailable", missing: nil, message: nil)
            throw STTClientError.sttUnavailable(err.message ?? err.error)
        default:
            let err = (try? JSONDecoder().decode(ErrorResponse.self, from: data))
            throw STTClientError.serverError(httpResponse.statusCode, err?.error ?? "unknown")
        }
    }

    /// Cancels a recording — the backend discards all spooled chunks.
    /// If the recording is already being processed (after 202), this signals
    /// the background worker to abort before submitting to Hermes.
    func cancel(recordingID: UUID) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.setValue("cancel", forHTTPHeaderField: "X-Action")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Cancel is best-effort — don't throw on failure
            return
        }
    }

    /// Sends a keepalive ping to the backend. Called periodically after submit
    /// (202) to signal that the client is still connected. The backend checks
    /// keepalive freshness before submitting to Hermes — if keepalives stop
    /// (app killed, out of range), the backend aborts processing.
    func keepalive(recordingID: UUID) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.setValue("keepalive", forHTTPHeaderField: "X-Action")

        // Best-effort — failures are silently ignored (the backend will
        // time out the keepalive and abort on its own).
        _ = try? await session.data(for: request)
    }

    // MARK: Health

    /// Checks STT backend health. No auth required on the server side.
    func health() async -> Bool {
        guard let url = baseURL.appendingPathComponent("health") as URL? else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
