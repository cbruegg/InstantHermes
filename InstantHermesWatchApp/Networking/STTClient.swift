//
//  STTClient.swift
//  InstantHermesWatchApp
//
//  HTTP client for the instanthermes-stt backend (:8643).
//  Handles chunk uploads, submit (finalize + transcribe), and cancel actions.
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

struct SubmitResponse: Decodable {
    let text: String
}

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
        config.timeoutIntervalForResource = 70 // submit: 60s + margin
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

    /// Submits a recording for transcription. Blocks until Voxtral completes.
    /// - Returns: The transcribed text.
    func submit(recordingID: UUID) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(recordingID.uuidString, forHTTPHeaderField: "X-Recording-ID")
        request.setValue("submit", forHTTPHeaderField: "X-Action")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let result = try JSONDecoder().decode(SubmitResponse.self, from: data)
            return result.text
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
