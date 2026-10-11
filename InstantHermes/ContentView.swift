//
//  ContentView.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    #if canImport(WatchConnectivity)
    @EnvironmentObject private var connectivityManager: WatchConnectivityManager
    #endif
    @Query private var items: [Item]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        }
        #if canImport(WatchConnectivity)
        .onAppear {
            connectivityManager.setModelContext(modelContext)
        }
        .onChange(of: items) { oldValue, newValue in
            connectivityManager.sendItems(newValue)
        }
        #endif
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
        #if canImport(WatchConnectivity)
        .environmentObject(WatchConnectivityManager.shared)
        #endif
}
