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
        guard let host = reply["host"] as? String,
              let apiKey = reply["apiKey"] as? String,
              !host.isEmpty, !apiKey.isEmpty else { return }

        let deliveryTarget = reply["deliveryTarget"] as? String ?? ""
        let config = ServerConfig(host: host, apiKey: apiKey, deliveryTarget: deliveryTarget)
        try? configStore.save(config)
        configReceived = true
    }

    /// Handles an incoming config push from the iPhone app.
    private func handleConfigMessage(_ message: [String: Any]) {
        guard let host = message["host"] as? String,
              let apiKey = message["apiKey"] as? String,
              !host.isEmpty, !apiKey.isEmpty else { return }

        let deliveryTarget = message["deliveryTarget"] as? String ?? ""
        let config = ServerConfig(host: host, apiKey: apiKey, deliveryTarget: deliveryTarget)
        try? configStore.save(config)
        configReceived = true
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
