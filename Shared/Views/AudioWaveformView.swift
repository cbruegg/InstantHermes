//
//  AudioWaveformView.swift
//  Shared between InstantHermes (iOS) and InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

/// A scrolling bar-waveform visualization of live audio input.
/// New levels push older ones out (right-to-left scroll), like a classic
/// voice recorder / equalizer display.
struct AudioWaveformView: View {
    /// Current normalized audio level (0.0–1.0).
    let level: Float
    /// Whether recording is active (controls color and scrolling).
    let isActive: Bool

    private let barCount = 25
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxBarHeight: CGFloat = 60
    private let minBarHeight: CGFloat = 2

    @State private var levels: [Float]

    init(level: Float, isActive: Bool, barCount: Int = 25) {
        self.level = level
        self.isActive = isActive
        self._levels = State(initialValue: Array(repeating: 0, count: barCount))
    }

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(barColor)
                    .frame(width: barWidth, height: CGFloat(level) * maxBarHeight + minBarHeight)
            }
        }
        .frame(height: maxBarHeight + minBarHeight)
        .onChange(of: level) { _, newLevel in
            guard isActive else { return }
            levels.append(newLevel)
            if levels.count > barCount {
                levels.removeFirst()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                withAnimation(.easeOut(duration: 0.4)) {
                    levels = Array(repeating: 0, count: barCount)
                }
            }
        }
    }

    private var barColor: Color {
        isActive ? .red : .gray.opacity(0.3)
    }
}

#Preview {
    VStack(spacing: 20) {
        AudioWaveformView(level: 0.5, isActive: true)
        AudioWaveformView(level: 0, isActive: false)
    }
    .padding()
}
