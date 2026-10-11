//
//  InstantHermesWatchApp.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

@main
struct InstantHermesWatchApp: App {
    // Keep a reference so the WCSession is activated on launch.
    @StateObject private var connectivityManager = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
