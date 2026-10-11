//
//  InstantHermesApp.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

@main
struct InstantHermesApp: App {
    #if canImport(WatchConnectivity)
    @StateObject private var connectivityManager = WatchConnectivityManager.shared
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if canImport(WatchConnectivity)
                .environmentObject(connectivityManager)
                #endif
        }
    }
}
