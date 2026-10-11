//
//  ContentView.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RecordingViewModel()
    @StateObject private var connectivityManager = WatchConnectivityManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Audio waveform visualization (active during recording)
            AudioWaveformView(
                level: viewModel.audioLevel,
                isActive: viewModel.isRecording
            )

            Spacer()

            // Status message (submitting)
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            // Not configured warning
            if !viewModel.isConfigured {
                Text("Open the iPhone app to set up the server")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            // Recording controls
            controls
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .onAppear {
            viewModel.checkConfiguration()
            // Start recording immediately on launch (if configured)
            viewModel.startRecordingIfIdle()
        }
        .onChange(of: connectivityManager.configReceived) { _, received in
            if received {
                viewModel.refreshConfiguration()
                // The config may have arrived after launch — start recording now
                viewModel.startRecordingIfIdle()
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.state {
        case .idle:
            Button("Start Recording") {
                viewModel.startRecording()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isConfigured)

        case .recording:
            HStack(spacing: 8) {
                Button("Cancel", role: .destructive) {
                    viewModel.cancelRecording()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Submit") {
                    viewModel.submitRecording()
                }
                .buttonStyle(.borderedProminent)
            }

        case .submitting:
            // Fire and forget: the submit POST is quick; no cancel once sent
            ProgressView()
                .controlSize(.small)
        }
    }
}

#Preview {
    ContentView()
}
