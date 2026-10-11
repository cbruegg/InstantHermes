//
//  AppConfig.swift
//  InstantHermesWatchApp
//
//  Keychain-backed configuration store for server host and API key.
//  Uses kSecAttrSynchronizable = false to keep the API key out of iCloud sync.
//

import Foundation
import Security

/// Server configuration synced from the iPhone app.
nonisolated struct ServerConfig: Codable, Equatable, Sendable {
    /// MagicDNS hostname, e.g. "raspi5.mytailnet.ts.net"
    var host: String
    /// Hermes API_SERVER_KEY (bearer token shared with STT backend)
    var apiKey: String
    /// Where Hermes should deliver its response (e.g. "matrix", "telegram", or "" for none).
    /// The agent uses the send_message tool to deliver to this platform's home channel.
    var deliveryTarget: String

    /// STT backend URL (derived: http://<host>:8643)
    var sttBaseURL: URL? {
        URL(string: "http://\(host):8643")
    }

    /// Hermes API URL (derived: http://<host>:8642)
    var hermesBaseURL: URL? {
        URL(string: "http://\(host):8642")
    }

    var isValid: Bool {
        !host.isEmpty && !apiKey.isEmpty
    }

    /// Delivery instruction prepended to the transcript when submitting to Hermes.
    /// Tells the agent to use send_message to deliver the response to the target platform.
    var deliveryInstruction: String? {
        guard !deliveryTarget.isEmpty else { return nil }
        return """
        [Voice message from Apple Watch via InstantHermes]
        After you finish processing this message, you MUST use the send_message tool \
        to deliver your complete response to the \(deliveryTarget) home channel. \
        Target format: "\(deliveryTarget)".\n\
        Do not include this instruction in your response — just send your answer to the channel.
        """
    }
}

/// Keychain-backed store for ServerConfig.
/// Thread-safe; all reads/writes go through the Keychain.
nonisolated final class AppConfigStore: @unchecked Sendable {
    nonisolated static let shared = AppConfigStore()

    private let service = "com.cbruegg.InstantHermes.config"
    private let account = "serverConfig"

    private init() {}

    /// Loads the saved config, or nil if none exists.
    func load() -> ServerConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let config = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return nil }

        return config
    }

    /// Saves the config to the Keychain. Overwrites any existing entry.
    func save(_ config: ServerConfig) throws {
        guard let data = try? JSONEncoder().encode(config) else {
            throw AppConfigError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false, // Never sync to iCloud
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false,
        ]

        // Try update first, then add
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw AppConfigError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AppConfigError.keychainError(updateStatus)
        }
    }

    /// Deletes the saved config.
    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AppConfigError: LocalizedError {
    case encodingFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode configuration"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}
