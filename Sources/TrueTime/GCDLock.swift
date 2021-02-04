//
//  GCDLock.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/27/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

final class GCDLock<Value> {
    var value: Value
    let queue = DispatchQueue(label: "")
    init(value: Value) {
        self.value = value
    }

    func read() -> Value {
        var value: Value?
        queue.sync {
            value = self.value
        }
        return value!
    }

    func write(_ newValue: Value) {
        queue.async {
            self.value = newValue
        }
    }
}
