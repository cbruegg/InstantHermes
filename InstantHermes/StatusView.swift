//
//  StatusView.swift
//  InstantHermes
//
//  Settings tab root view for the iPhone app. Shows server status,
//  watch connectivity status, and a link to the configuration form.
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

struct StatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if canImport(WatchConnectivity)
    @EnvironmentObject private var connectivityManager: WatchConnectivityManager
    #endif

    @State private var isConfigured = false
    @State private var serverHost: String = ""

    private let configStore = AppConfigStore.shared

    var body: some View {
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
                    if !connectivityManager.isSupported {
                        Text("Not supported")
                            .foregroundStyle(.secondary)
                    } else if connectivityManager.activationError != nil {
                        Text("Connection error")
                            .foregroundStyle(.red)
                    } else if connectivityManager.activationState != .activated {
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    } else if !connectivityManager.isPaired {
                        Text("No paired watch")
                            .foregroundStyle(.orange)
                    } else if connectivityManager.isWatchAppInstalled {
                        if connectivityManager.isReachable {
                            Text("Connected")
                                .foregroundStyle(.green)
                        } else {
                            Text("Installed, not reachable")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("App not detected")
                            .foregroundStyle(.red)
                    }
                }
                #endif
            } header: {
                Text("Status")
            } footer: {
                #if canImport(WatchConnectivity)
                Text(connectivityManager.connectionDetails)
                if !connectivityManager.isWatchAppInstalled {
                    Text("Install the iPhone app with its embedded watch companion, then open the app on your paired Apple Watch. Pull down to refresh.")
                } else if !isConfigured {
                    Text("Tap Configure to set up your Hermes server. Make sure Tailscale is running on this device.")
                } else {
                    Text("Record voice messages on this device or your Apple Watch to send them to Hermes. Keep your iPhone nearby — the watch routes traffic through it. Make sure Tailscale is running on your iPhone.")
                }
                #else
                if !isConfigured {
                    Text("Tap Configure to set up your Hermes server. Make sure Tailscale is running on this device.")
                } else {
                    Text("Record voice messages to send them to Hermes. Make sure Tailscale is running on this device.")
                }
                #endif
            }

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Configure", systemImage: "gear")
                }
            }
        }
        .navigationTitle("Settings")
        .refreshable {
            refreshStatus()
        }
        .onAppear {
            refreshStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshStatus()
            }
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
        #if canImport(WatchConnectivity)
        connectivityManager.refreshWatchStatus()
        #endif
    }
}

#Preview {
    NavigationStack {
        StatusView()
        #if canImport(WatchConnectivity)
        .environmentObject(WatchConnectivityManager.shared)
        #endif
    }
}
