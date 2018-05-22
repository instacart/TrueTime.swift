//
//  DispatchBlockTimer.swift
//  TrueTime-iOS
//
//  Created by Michael Sanders on 5/22/18.
//  Copyright © 2018 Instacart. All rights reserved.
//

import Foundation

final class DispatchBlockTimer {
    init(timeInterval: TimeInterval, handler: @escaping (DispatchBlockTimer) -> Void) {
        self.timeInterval = timeInterval
        self.handler = handler
    }

    static func scheduled(timeInterval: TimeInterval,
                          handler: @escaping (DispatchBlockTimer) -> Void) -> DispatchBlockTimer {
        let timer = DispatchBlockTimer(timeInterval: timeInterval, handler: handler)
        timer.start()
        return timer
    }

    deinit {
        cancel()
    }

    func start() {
        guard source == nil else { return }
        source = DispatchSource.makeTimerSource()
        source?.schedule(deadline: .now() + timeInterval)
        source?.setEventHandler {
            self.handler(self)
        }
        source?.resume()
    }

    func cancel() {
        guard let source = source else { return }
        source.setEventHandler(handler: nil)
        source.cancel()
        self.source = nil
    }

    private let timeInterval: TimeInterval
    private let handler: (DispatchBlockTimer) -> Void
    private var source: DispatchSourceTimer?
}
