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
    let queue: dispatch_queue_t = dispatch_queue_create(nil, nil)
    init(value: Value) {
        self.value = value
    }

    func read() -> Value {
        var value: Value?
        dispatch_sync(queue) {
            value = self.value
        }
        return value!
    }

    func write(newValue: Value) {
        dispatch_async(queue) {
            self.value = newValue
        }
    }
}
