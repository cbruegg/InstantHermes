//
//  Item.swift
//  InstantHermes
//
//  Created by Christian Brüggemann on 11.10.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
