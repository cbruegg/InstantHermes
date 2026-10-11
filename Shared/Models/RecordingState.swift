//
//  RecordingState.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation

/// The lifecycle state of a recording session.
///
/// State machine:
/// ```
/// idle
///   └─ start ─→ recording ── Submit / 3s silence ──→ submitting ── 202 ──→ idle
///                   │                                      │
///                   └─ Cancel ─────────────────────────────┘
/// ```
///
/// Fire and forget: once the backend accepts the submit (202), it transcribes
/// the audio and forwards the transcript to Hermes in the background.
/// The device never waits for transcription.
///
/// Cancel is available in both `recording` and `submitting` states:
/// - In `recording`: discards spooled chunks on the backend.
/// - In `submitting`: interrupts the submit task and sends a cancel to the
///   backend, which aborts processing (transcription + Hermes submission).
/// After 202, the device sends periodic keepalives so the backend can detect
/// client disconnection and abort.
enum RecordingState: Equatable, Sendable {
    /// No recording in progress.
    case idle
    /// Actively recording and streaming PCM chunks.
    case recording
    /// Submit POST in flight. Cancel is still available — it interrupts the
    /// submit task (if the POST hasn't been sent) and signals the backend to
    /// abort processing. Once the backend accepts (202), the device returns
    /// to idle and starts sending keepalives.
    case submitting
}
