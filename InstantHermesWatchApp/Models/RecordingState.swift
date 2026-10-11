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
///   └─ start ─→ recording ── Submit / 3s silence ──→ transcribing ── transcript ──→ submitting ── 202 ──→ idle
///                   │                                      │
///                   └─ Cancel ──→ idle                     └─ Cancel ──→ idle (discard transcript)
/// ```
enum RecordingState: Equatable, Sendable {
    /// No recording in progress.
    case idle
    /// Actively recording and streaming AAC chunks.
    case recording
    /// Recording stopped; waiting for Voxtral transcription (Submit tapped).
    /// Cancel is still available — the transcript is discarded when it arrives.
    case transcribing
    /// Transcript received; POSTing to Hermes /v1/runs.
    /// No cancel — 202 is the point of no return.
    case submitting
}
