//
//  SettingsView.swift
//  InstantHermes
//
//  Settings UI for server host and API key configuration.
//  Config is stored in the Keychain and synced to the Apple Watch.
//

import SwiftUI

struct SettingsView: View {
    @State private var host: String = ""
    @State private var apiKey: String = ""
    @State private var deliveryTarget: String = ""
    @State private var showSavedAlert = false
    @State private var errorMessage: String?
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String?

    private let configStore = AppConfigStore.shared

    /// Available delivery targets for the picker.
    private let deliveryTargets = ["", "matrix", "telegram", "discord", "slack", "whatsapp", "signal"]

    #if canImport(WatchConnectivity)
    @EnvironmentObject private var connectivityManager: WatchConnectivityManager
    #endif

    var body: some View {
        Form {
            Section {
                TextField("raspi5.mytailnet.ts.net", text: $host)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("Enter the MagicDNS hostname of your Hermes server (e.g. raspi5.mytailnet.ts.net) and the API_SERVER_KEY from ~/.hermes/.env.")
            }

            Section {
                Picker("Reply in", selection: $deliveryTarget) {
                    ForEach(deliveryTargets, id: \.self) { target in
                        if target.isEmpty {
                            Text("Nowhere (fire-and-forget)").tag(target)
                        } else {
                            Text(target.capitalized).tag(target)
                        }
                    }
                }
            } header: {
                Text("Response Delivery")
            } footer: {
                Text("Where should Hermes deliver its response? Hermes will use the send_message tool to post its reply to this platform's home channel. Leave as \"Nowhere\" for fire-and-forget mode (Hermes processes but doesn't reply anywhere).")
            }

            Section {
                Button("Save") {
                    saveConfig()
                }
                .disabled(host.isEmpty || apiKey.isEmpty)

                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(host.isEmpty || apiKey.isEmpty || isTestingConnection)
            }

            if let result = connectionTestResult {
                Section {
                    Text(result)
                        .foregroundStyle(result.contains("✓") ? .green : .red)
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            #if canImport(WatchConnectivity)
            Section {
                HStack {
                    Text("Watch")
                    Spacer()
                    if connectivityManager.isReachable {
                        Label("Connected", systemImage: "applewatch")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not reachable", systemImage: "applewatch.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Configuration is automatically synced to your Apple Watch when it's reachable.")
            }
            #endif
        }
        .navigationTitle("Settings")
        .onAppear {
            loadConfig()
        }
        .alert("Saved", isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    private func loadConfig() {
        if let config = configStore.load() {
            host = config.host
            apiKey = config.apiKey
            deliveryTarget = config.deliveryTarget
        }
    }

    private func saveConfig() {
        let config = ServerConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
            deliveryTarget: deliveryTarget.trimmingCharacters(in: .whitespaces)
        )
        do {
            try configStore.save(config)
            #if canImport(WatchConnectivity)
            connectivityManager.syncConfigToWatch()
            #endif
            showSavedAlert = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        let config = ServerConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
            deliveryTarget: deliveryTarget.trimmingCharacters(in: .whitespaces)
        )

        // Test Hermes health
        guard let hermesURL = config.hermesBaseURL else {
            connectionTestResult = "✗ Invalid host"
            return
        }

        let healthURL = hermesURL.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Also test STT backend
                if let sttURL = config.sttBaseURL {
                    let sttHealthURL = sttURL.appendingPathComponent("health")
                    var sttRequest = URLRequest(url: sttHealthURL)
                    sttRequest.timeoutInterval = 5
                    let (_, sttResponse) = try await URLSession.shared.data(for: sttRequest)
                    if let sttHttp = sttResponse as? HTTPURLResponse, sttHttp.statusCode == 200 {
                        connectionTestResult = "✓ Both Hermes and STT reachable"
                    } else {
                        connectionTestResult = "✓ Hermes reachable, STT not responding"
                    }
                } else {
                    connectionTestResult = "✓ Hermes reachable"
                }
            } else {
                connectionTestResult = "✗ Hermes returned \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            }
        } catch {
            connectionTestResult = "✗ Connection failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
        #if canImport(WatchConnectivity)
        .environmentObject(WatchConnectivityManager.shared)
        #endif
    }
}
