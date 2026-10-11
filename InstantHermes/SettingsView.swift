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

                // Show validation warning inline
                if let warning = validateHost() {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("Enter the hostname (e.g. raspi5.YOURTAILNET.ts.net or raspi5.cbruegg.com) and the API_SERVER_KEY from ~/.hermes/.env. Use a domain name, NOT an IP address — ATS blocks HTTP to IPs.")
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
        // Normalize host (strip protocol and trailing slash)
        var normalizedHost = host.trimmingCharacters(in: .whitespaces)
        if normalizedHost.hasPrefix("http://") { normalizedHost = String(normalizedHost.dropFirst(7)) }
        if normalizedHost.hasPrefix("https://") { normalizedHost = String(normalizedHost.dropFirst(8)) }
        if normalizedHost.hasSuffix("/") { normalizedHost = String(normalizedHost.dropLast()) }

        let config = ServerConfig(
            host: normalizedHost,
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

    /// Validates the host field. Returns an error message if invalid.
    private func validateHost() -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil } // Empty is OK (just not saved)

        // Strip protocol if user accidentally included it
        var h = trimmed
        if h.hasPrefix("http://") { h = String(h.dropFirst(7)) }
        if h.hasPrefix("https://") { h = String(h.dropFirst(8)) }
        // Strip trailing slash
        if h.hasSuffix("/") { h = String(h.dropLast()) }

        // Check if it looks like an IP address (ATS exceptions don't work for IPs)
        let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        if h.range(of: ipPattern, options: .regularExpression) != nil {
            return "IP addresses don't work — use the MagicDNS hostname (e.g. raspi5.mytailnet.ts.net). ATS blocks HTTP to IPs."
        }

        // Check if it contains a dot (looks like a domain)
        if !h.contains(".") {
            return "Enter the full MagicDNS hostname (e.g. raspi5.mytailnet.ts.net), not just 'raspi5'."
        }

        // Warn if it doesn't match an ATS-exception domain
        let allowedSuffixes = [".ts.net", ".cbruegg.com"]
        if !allowedSuffixes.contains(where: { h.hasSuffix($0) }) {
            return "ATS exception is only configured for *.ts.net and *.cbruegg.com domains. Other domains will be blocked."
        }

        return nil
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        // Validate host first
        if let warning = validateHost() {
            connectionTestResult = "⚠ \(warning)"
            return
        }

        // Normalize host (strip protocol and trailing slash)
        var normalizedHost = host.trimmingCharacters(in: .whitespaces)
        if normalizedHost.hasPrefix("http://") { normalizedHost = String(normalizedHost.dropFirst(7)) }
        if normalizedHost.hasPrefix("https://") { normalizedHost = String(normalizedHost.dropFirst(8)) }
        if normalizedHost.hasSuffix("/") { normalizedHost = String(normalizedHost.dropLast()) }

        let config = ServerConfig(
            host: normalizedHost,
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
        } catch let error as NSError {
            // Check for ATS error specifically
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                connectionTestResult = "✗ ATS blocked: Use a domain name (raspi5.xxx.ts.net or raspi5.cbruegg.com), not an IP address. ATS exceptions only work for domain names."
            } else if error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotConnectToHost {
                connectionTestResult = "✗ Cannot connect — is Tailscale running on this iPhone? Is the host correct?"
            } else if error.domain == NSURLErrorDomain && error.code == NSURLErrorNotConnectedToInternet {
                connectionTestResult = "✗ No internet — is Tailscale running on this iPhone?"
            } else {
                connectionTestResult = "✗ \(error.localizedDescription)"
            }
        } catch {
            connectionTestResult = "✗ \(error.localizedDescription)"
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
