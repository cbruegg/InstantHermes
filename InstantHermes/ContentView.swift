//
//  ContentView.swift
//  InstantHermes
//
//  Main view for the iPhone app. A TabView with two tabs:
//  - Record: the shared recording interface (same as the watch app)
//  - Settings: server status and configuration
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            // Record tab — the primary interface, same as the watch app
            NavigationStack {
                RecordingView()
                    .navigationTitle("Record")
            }
            .tabItem {
                Label("Record", systemImage: "mic.fill")
            }

            // Settings tab — status overview + configuration
            NavigationStack {
                StatusView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
    }
}

#Preview {
    ContentView()
        #if canImport(WatchConnectivity)
        .environmentObject(WatchConnectivityManager.shared)
        #endif
}
