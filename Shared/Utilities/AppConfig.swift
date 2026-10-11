//
//  AppConfig.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  Keychain-backed configuration store for server host and API key.
//  Uses kSecAttrSynchronizable = false to keep the API key out of iCloud sync.
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import Security

/// Server configuration: Hermes host + API key + delivery target.
nonisolated struct ServerConfig: Codable, Equatable, Sendable {
    /// MagicDNS hostname, e.g. "raspi5.mytailnet.ts.net"
    var host: String
    /// Hermes API_SERVER_KEY (bearer token shared with STT backend)
    var apiKey: String
    /// Where the Hermes response should be delivered (e.g. "matrix", "telegram",
    /// or "" for none). Synced to the watch; the STT backend delivers the
    /// response to this platform's home channel.
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
