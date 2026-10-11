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
                        if connectivityManager.isWatchAppInstalled {
                            if connectivityManager.isReachable {
                                Text("Connected")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Installed, not reachable")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Not installed")
                                .foregroundStyle(.red)
                        }
                    }
                    #endif
                } header: {
                    Text("Status")
                } footer: {
                    #if canImport(WatchConnectivity)
                    if !connectivityManager.isWatchAppInstalled {
                        Text("The watch app should auto-install from the Watch app → App Store → 'Apps' section, or open the Watch app on your iPhone and look for the install prompt.")
                    } else if !isConfigured {
                        Text("Tap Settings to configure your Hermes server. Make sure Tailscale is running on this device.")
                    } else {
                        Text("Record voice messages on your Apple Watch to send them to Hermes. Keep your iPhone nearby — the watch routes traffic through it. Make sure Tailscale is running on your iPhone.")
                    }
                    #else
                    if !isConfigured {
                        Text("Tap Settings to configure your Hermes server. Make sure Tailscale is running on this device.")
                    } else {
                        Text("Record voice messages on your Apple Watch to send them to Hermes. Make sure Tailscale is running on this device.")
                    }
                    #endif
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
