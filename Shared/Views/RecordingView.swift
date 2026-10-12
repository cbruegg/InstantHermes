//
//  RecordingView.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  The main recording interface. Used as the primary screen on both iOS
//  (as the "Record" tab) and watchOS (as the only screen).
//
//  Platform differences are handled via conditional compilation:
//  - watchOS: observes WatchConnectivity for config sync from iPhone,
//    auto-starts recording on launch AND on resume (scenePhase → .active),
//    compact layout.
//  - iOS: config is local (edited in the Settings tab), auto-starts on
//    launch only (no auto-start on resume), larger layout.
//
//  The watchOS-only auto-start-on-resume is intentional: the watch app is
//  a "glance and speak" interface where reopening the app should immediately
//  begin recording. On iOS, the app is a full app with tabs; auto-starting
//  on every resume would be surprising when the user just wants to check
//  settings or history.
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

struct RecordingView: View {
    @StateObject private var viewModel = RecordingViewModel()
    #if os(watchOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    /// Whether to auto-start recording when the view appears and config is ready.
    /// Both platforms default to true — the product is "instant" voice capture.
    var autoStart: Bool = true

    var body: some View {
        VStack(spacing: contentSpacing) {
            Spacer()

            // Audio waveform visualization (active during recording)
            AudioWaveformView(
                level: viewModel.audioLevel,
                isActive: viewModel.isRecording
            )
            .frame(height: waveformHeight)

            Spacer()

            // Status message (submitting)
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(statusFont)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(errorFont)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            // Not configured warning
            if !viewModel.isConfigured {
                Text(notConfiguredMessage)
                    .font(statusFont)
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
            if autoStart {
                viewModel.startRecordingIfIdle()
            }
        }
        #if os(watchOS)
        // INTENTIONAL watchOS-only behavior: auto-start recording when the
        // app resumes (user reopens the already-running app). This is by
        // design — the watch is a "raise and speak" interface. iOS does NOT
        // do this; see the file header comment for the rationale.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && autoStart {
                viewModel.startRecordingIfIdle()
            }
        }
        .onChange(of: WatchConnectivityManager.shared.configReceived) { _, received in
            if received {
                viewModel.refreshConfiguration()
                // The config may have arrived after launch — start recording now
                if autoStart {
                    viewModel.startRecordingIfIdle()
                }
            }
        }
        .onChange(of: WatchConnectivityManager.shared.lastReceivedConfig) { _, newConfig in
            guard newConfig != nil else { return }
            // Settings were updated on the iPhone while we were recording with
            // the old config — cancel so the user can start fresh. This goes
            // through the normal cancel path (idle UI, no error message).
            viewModel.cancelRecording()
        }
        #endif
    }

    // MARK: - Controls

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
            // Submit POST in flight — Cancel is still available.
            // Tapping Cancel interrupts the submit task (if the POST hasn't
            // been sent) and sends a cancel to the backend, which aborts
            // processing before transcription and before the Hermes POST.
            HStack(spacing: 8) {
                Button("Cancel", role: .destructive) {
                    viewModel.cancelRecording()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Platform Adaptations

    #if os(watchOS)
    private var contentSpacing: CGFloat { 12 }
    private var waveformHeight: CGFloat { 62 } // maxBarHeight + minBarHeight
    private var statusFont: Font { .caption2 }
    private var errorFont: Font { .caption2 }
    private var notConfiguredMessage: String {
        "Open the iPhone app to set up the server"
    }
    #else
    private var contentSpacing: CGFloat { 20 }
    private var waveformHeight: CGFloat { 120 }
    private var statusFont: Font { .subheadline }
    private var errorFont: Font { .subheadline }
    private var notConfiguredMessage: String {
        "Configure the server in the Settings tab"
    }
    #endif
}

#Preview {
    RecordingView()
}
