//
//  RecordingState.swift
//  InstantHermesWatchApp
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
///                   │
///                   └─ Cancel ──→ idle
/// ```
///
/// Fire and forget: once the backend accepts the submit (202), it transcribes
/// the audio and forwards the transcript to Hermes in the background.
/// The watch never waits for transcription.
enum RecordingState: Equatable, Sendable {
    /// No recording in progress.
    case idle
    /// Actively recording and streaming PCM chunks.
    case recording
    /// Submit POST in flight. No cancel — once the backend accepts the audio,
    /// transcription and Hermes submission happen server-side.
    case submitting
}
