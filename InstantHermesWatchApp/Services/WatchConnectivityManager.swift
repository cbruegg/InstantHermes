//
//  WatchConnectivityManager.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Manages the WatchConnectivity session for communication with the companion iPhone app.
/// Currently only tracks reachability; item syncing has been removed.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isCompanionAppInstalled = false

    #if canImport(WatchConnectivity)
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    #endif

    private override init() {
        super.init()
        #if canImport(WatchConnectivity)
        session?.delegate = self
        session?.activate()
        #endif
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
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }
}
#endif
