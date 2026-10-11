//
//  ContentView.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RecordingViewModel()

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Audio waveform visualization
            AudioWaveformView(
                level: viewModel.audioLevel,
                isActive: viewModel.isRecording
            )

            Spacer()

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Recording controls
            if viewModel.isRecording {
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

                Text("Auto-submits after 3s of silence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Start Recording") {
                    viewModel.startRecording()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            // Start recording immediately on launch
            viewModel.startRecording()
        }
    }
}

#Preview {
    ContentView()
}
