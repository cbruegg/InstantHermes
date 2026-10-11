//
//  WatchConnectivityManager.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//

#if canImport(WatchConnectivity)
import Foundation
import Combine
import WatchConnectivity
import SwiftData

@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isWatchAppInstalled = false
    @Published var isReachable = false

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var modelContext: ModelContext?

    private override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func sendItems(_ items: [Item]) {
        guard let session, session.isReachable else { return }
        let data = items.map { ["timestamp": $0.timestamp.timeIntervalSince1970] }
        session.sendMessage(["items": data], replyHandler: nil)
    }

    private func replaceItems(with timestamps: [TimeInterval]) {
        guard let modelContext else { return }
        // Delete all existing items
        try? modelContext.delete(model: Item.self)
        // Insert new items
        for timestamp in timestamps {
            modelContext.insert(Item(timestamp: Date(timeIntervalSince1970: timestamp)))
        }
        try? modelContext.save()
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
            if let itemsData = message["items"] as? [[String: Any]] {
                let timestamps = itemsData.compactMap { $0["timestamp"] as? TimeInterval }
                self.replaceItems(with: timestamps)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            if let request = message["request"] as? String, request == "items" {
                // Watch is requesting current items
                // The reply will be sent via sendItems when the view updates
            }
            replyHandler([:])
        }
    }
}
#endif
