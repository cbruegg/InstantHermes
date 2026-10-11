//
//  ContentView.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//
//  Main view for the iPhone app. Shows server status and a link to settings.
//

import SwiftUI

struct ContentView: View {
    #if canImport(WatchConnectivity)
    @EnvironmentObject private var connectivityManager: WatchConnectivityManager
    #endif

    @State private var showSettings = false
    @State private var isConfigured = false
    @State private var serverHost: String = ""

    private let configStore = AppConfigStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Server", systemImage: "server.rack")
                        Spacer()
                        if isConfigured {
                            Text(serverHost)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not configured")
                                .foregroundStyle(.red)
                        }
                    }

                    #if canImport(WatchConnectivity)
                    HStack {
                        Label("Apple Watch", systemImage: "applewatch")
                        Spacer()
                        if connectivityManager.isReachable {
                            Text("Connected")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not reachable")
                                .foregroundStyle(.secondary)
                        }
                    }
                    #endif
                } header: {
                    Text("Status")
                } footer: {
                    if !isConfigured {
                        Text("Tap Settings to configure your Hermes server. Make sure Tailscale is running on this device.")
                    } else {
                        Text("Record voice messages on your Apple Watch to send them to Hermes. Make sure Tailscale is running on this device.")
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .navigationTitle("InstantHermes")
        }
        .onAppear {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        if let config = configStore.load(), config.isValid {
            isConfigured = true
            serverHost = config.host
        } else {
            isConfigured = false
            serverHost = ""
        }
    }
}

#Preview {
    ContentView()
    #if canImport(WatchConnectivity)
    .environmentObject(WatchConnectivityManager.shared)
    #endif
}
