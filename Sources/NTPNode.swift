//
//  NTPNode.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/18/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

protocol SNTPNode: class {
    var timeout: NSTimeInterval { get }
    var started: Bool { get }
    var timerQueue: dispatch_queue_t { get }
    var timer: dispatch_source_t? { get set }
    func timeoutError(error: NSError)
}

extension SNTPNode {
    func startTimer() {
        cancelTimer()
        timer = dispatchTimer(after: timeout, queue: timerQueue) {
            guard self.started else { return }
            debugLog("Got timeout connecting to \(self)")
            self.timeoutError(NSError(trueTimeError: .TimedOut))
        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
