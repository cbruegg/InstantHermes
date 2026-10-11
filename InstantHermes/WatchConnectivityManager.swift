//
//  WatchConnectivityManager.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//
//  Manages WatchConnectivity for syncing server config (host + API key)
//  to the Apple Watch app.
//

#if canImport(WatchConnectivity)
import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isWatchAppInstalled = false
    @Published var isReachable = false

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let configStore: AppConfigStore

    private override init() {
        self.configStore = .shared
        super.init()
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Config Sync

    /// Sends the current server config to the watch.
    func syncConfigToWatch() {
        guard let session, session.isReachable else { return }
        guard let config = configStore.load(), config.isValid else { return }

        let message: [String: Any] = [
            "host": config.host,
            "apiKey": config.apiKey,
            "deliveryTarget": config.deliveryTarget,
        ]

        // Try sendMessage first (watch is in foreground)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: { _ in
                // Fall back to transferUserInfo (works in background)
                session.transferUserInfo(message)
            })
        } else {
            session.transferUserInfo(message)
        }

        // Also update the application context so the watch gets it on next launch
        try? session.updateApplicationContext(message)
    }

    /// Saves config and syncs it to the watch.
    func saveAndSyncConfig(_ config: ServerConfig) throws {
        try configStore.save(config)
        syncConfigToWatch()
    }
}

// MARK: - WCSessionDelegate
nonisolated extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isReachable = session.isReachable
            // Sync config when session activates
            if activationState == .activated {
                self.syncConfigToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Required on iOS, not available on watchOS
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS, re-activate the session
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable {
                self.syncConfigToWatch()
            }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchAppInstalled = session.isWatchAppInstalled
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            // Watch might be requesting config
            if let request = message["request"] as? String, request == "serverConfig" {
                self.syncConfigToWatch()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
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

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        // Watch sent us something via transferUserInfo (not used currently)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        // Watch updated its context (not used currently)
    }
}
#endif
