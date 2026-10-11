//
//  RecordingState.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation

/// The lifecycle state of a recording session.
enum RecordingState: Equatable, Sendable {
    /// No recording in progress.
    case idle
    /// Actively recording and streaming audio.
    case recording
}
