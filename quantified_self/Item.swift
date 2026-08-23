//
//  Item.swift
//  quantified_self
//
//  Created by Clemens Gerbaulet on 23.08.26.
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
