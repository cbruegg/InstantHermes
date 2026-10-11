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
    @Published private(set) var isPaired = false
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var activationError: String?

    var isSupported: Bool { session != nil }

    var connectionDetails: String {
        guard isSupported else { return "WatchConnectivity is not supported on this device." }
        if let activationError {
            return "WatchConnectivity activation failed: \(activationError)"
        }
        guard activationState == .activated else {
            return "WatchConnectivity is not active yet. Installation status is unknown."
        }
        return "Session: activated · Paired: \(isPaired ? "yes" : "no") · App detected: \(isWatchAppInstalled ? "yes" : "no") · Reachable: \(isReachable ? "yes" : "no")"
    }

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let configStore: AppConfigStore

    private override init() {
        self.configStore = .shared
        super.init()
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Status Refresh

    /// Re-reads the session state when the app returns to the foreground or is refreshed.
    func refreshWatchStatus() {
        guard let session else { return }
        activationState = session.activationState
        // Installation and pairing properties are only meaningful after activation.
        guard activationState == .activated else {
            isPaired = false
            isWatchAppInstalled = false
            isReachable = false
            return
        }
        activationError = nil
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
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
            self.refreshWatchStatus()
            self.activationError = error?.localizedDescription
            // Sync config when session activates
            if activationState == .activated {
                self.syncConfigToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.refreshWatchStatus()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS, re-activate the session
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshWatchStatus()
            if session.isReachable {
                self.syncConfigToWatch()
            }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshWatchStatus()
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
