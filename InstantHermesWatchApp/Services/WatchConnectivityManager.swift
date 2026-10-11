//
//  WatchConnectivityManager.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//
//  Manages WatchConnectivity for receiving server config (host + API key)
//  from the companion iPhone app. Stores config in the Keychain.
//

import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Manages the WatchConnectivity session for communication with the companion iPhone app.
/// Receives server config (host + API key) and stores it in the Keychain.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isCompanionAppInstalled = false
    @Published var configReceived = false
    /// Set when a config received from the iPhone differs from the previously
    /// cached config. Observers can use this to react to settings changes
    /// (e.g. cancel an in-progress recording that was started with stale settings).
    @Published private(set) var lastReceivedConfig: ServerConfig?

    private let configStore: AppConfigStore

    #if canImport(WatchConnectivity)
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    #endif

    private override init() {
        self.configStore = .shared
        super.init()
        #if canImport(WatchConnectivity)
        session?.delegate = self
        session?.activate()
        #endif
        // Check if we already have a saved config
        configReceived = configStore.load() != nil
    }

    /// Requests the current config from the iPhone app.
    func requestConfigFromiPhone() {
        #if canImport(WatchConnectivity)
        guard let session, session.isReachable else { return }
        session.sendMessage(
            ["request": "serverConfig"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.handleConfigReply(reply)
                }
            },
            errorHandler: nil
        )
        #endif
    }

    private func handleConfigReply(_ reply: [String: Any]) {
        processIncomingConfig(reply)
    }

    /// Handles an incoming config push from the iPhone app.
    private func handleConfigMessage(_ message: [String: Any]) {
        processIncomingConfig(message)
    }

    /// Parses an incoming config from the iPhone, saves it to the Keychain,
    /// and signals a change if it differs from the previously cached config.
    private func processIncomingConfig(_ payload: [String: Any]) {
        guard let host = payload["host"] as? String,
              let apiKey = payload["apiKey"] as? String,
              !host.isEmpty, !apiKey.isEmpty else { return }

        let deliveryTarget = payload["deliveryTarget"] as? String ?? ""
        let newConfig = ServerConfig(host: host, apiKey: apiKey, deliveryTarget: deliveryTarget)

        let oldConfig = configStore.load()
        try? configStore.save(newConfig)
        configReceived = true

        // Signal a change only if there was a previous config that differs.
        // This avoids a spurious "change" on first-time setup (oldConfig == nil),
        // where the recording hasn't started yet and there's nothing to cancel.
        if let oldConfig, oldConfig != newConfig {
            lastReceivedConfig = newConfig
        }
    }
}

#if canImport(WatchConnectivity)
// MARK: - WCSessionDelegate
nonisolated extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.isCompanionAppInstalled = session.isCompanionAppInstalled
            // Request config from iPhone when the session activates
            if activationState == .activated {
                self.requestConfigFromiPhone()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Re-request config when iPhone becomes reachable
            if session.isReachable {
                self.requestConfigFromiPhone()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            self.handleConfigMessage(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            // iPhone might be requesting config (not typical, but handle it)
            if let request = message["request"] as? String, request == "serverConfig" {
                if let config = self.configStore.load() {
                    replyHandler([
                        "host": config.host,
                        "apiKey": config.apiKey,
                        "deliveryTarget": config.deliveryTarget,
                    ])
                } else {
                    replyHandler([:])
                }
            } else {
                replyHandler([:])
            }
        }
    }
}
#endif
