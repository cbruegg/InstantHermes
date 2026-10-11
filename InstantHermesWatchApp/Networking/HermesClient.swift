//
//  HermesClient.swift
//  InstantHermesWatchApp
//
//  HTTP client for the Hermes API server (:8642).
//  Handles /v1/runs (message submission) and /health (connectivity check).
//

import Foundation

// MARK: - Errors

enum HermesClientError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(Int, String)
    case emptyInput
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured. Set up the server in the iPhone app."
        case .invalidResponse:
            return "Invalid response from Hermes server"
        case .serverError(let code, let message):
            return "Hermes server error (\(code)): \(message)"
        case .emptyInput:
            return "Cannot submit empty message"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Request/Response types

struct RunRequest: Encodable {
    let input: String
}

struct RunResponse: Decodable {
    let run_id: String
    let status: String
}

struct HealthResponse: Decodable {
    let status: String
}

struct HermesErrorResponse: Decodable {
    let error: String?
    let message: String?
    let detail: String?
}

// MARK: - Hermes Client

/// Client for the Hermes API server.
/// All requests carry `Authorization: Bearer <apiKey>`.
final class HermesClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init?(config: ServerConfig) {
        guard let url = config.hermesBaseURL, !config.apiKey.isEmpty else {
            return nil
        }
        self.baseURL = url
        self.apiKey = config.apiKey
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: Health

    /// Checks Hermes API server health. No auth required.
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

    // MARK: Submit Message

    /// Submits a transcript to Hermes as a fire-and-forget run.
    /// - Parameters:
    ///   - text: The transcribed text to send.
    ///   - idempotencyKey: Unique key for safe retries (use the recording UUID).
    ///   - deliveryInstruction: Optional instruction telling the agent where to deliver
    ///     the response (e.g. "send your response to the matrix home channel").
    /// - Returns: The run ID from Hermes.
    @discardableResult
    func submitMessage(text: String, idempotencyKey: UUID, deliveryInstruction: String? = nil) async throws -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HermesClientError.emptyInput
        }

        // Prepend delivery instructions if configured
        if let instruction = deliveryInstruction, !instruction.isEmpty {
            trimmed = instruction + "\n\nUser said: " + trimmed
        }

        let url = baseURL.appendingPathComponent("v1/runs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(RunRequest(input: trimmed))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 202:
            let result = try JSONDecoder().decode(RunResponse.self, from: data)
            return result.run_id
        default:
            let err = (try? JSONDecoder().decode(HermesErrorResponse.self, from: data))
            let message = err?.message ?? err?.detail ?? err?.error ?? "unknown error"
            throw HermesClientError.serverError(httpResponse.statusCode, message)
        }
    }
}
