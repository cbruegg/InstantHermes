//
//  ContentView.swift
//  InstantHermesWatchApp
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @StateObject private var connectivityManager = WatchConnectivityManager.shared
    @StateObject private var audioRecorder = AudioRecorderManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Recording status
                HStack(spacing: 6) {
                    Circle()
                        .fill(audioRecorder.isRecording ? Color.red : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(audioRecorder.isRecording ? "Recording" : "Not recording")
                        .font(.caption)
                        .foregroundStyle(audioRecorder.isRecording ? .red : .secondary)
                }

                // Error message
                if let error = audioRecorder.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Recording controls
                if audioRecorder.isRecording {
                    HStack(spacing: 8) {
                        Button("Cancel", role: .destructive) {
                            audioRecorder.stopRecording()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button("Submit") {
                            audioRecorder.submitRecording()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("Auto-submits after 3s of silence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Start Recording") {
                        audioRecorder.startRecording()
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Items list
                List {
                    ForEach(items) { item in
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .navigationTitle("InstantHermes")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear {
            connectivityManager.setModelContext(modelContext)
            connectivityManager.requestItems()
            // Start recording immediately on launch
            audioRecorder.startRecording()
        }
        .onChange(of: items) { oldValue, newValue in
            connectivityManager.sendItems(newValue)
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
