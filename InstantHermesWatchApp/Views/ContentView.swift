//
//  ContentView.swift
//  InstantHermesWatchApp
//
//  Thin wrapper around the shared RecordingView. The watch app's main
//  (and only) screen is the recording interface, identical to the iOS
//  app's Record tab.
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        RecordingView()
    }
}

#Preview {
    ContentView()
}
