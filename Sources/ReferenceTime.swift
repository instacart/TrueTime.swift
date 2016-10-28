//
//  FrozenReferenceTime.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/26/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Result

typealias FrozenReferenceTimeResult = Result<FrozenReferenceTime, NSError>
typealias FrozenReferenceTimeCallback = FrozenReferenceTimeResult -> Void

protocol ReferenceTimeContainer {
    var time: NSDate { get }
    var uptime: timeval { get }
    func now() -> NSDate
    init(time: NSDate, uptime: timeval)
}

struct FrozenReferenceTime: ReferenceTimeContainer {
    let time: NSDate
    let uptime: timeval
    let serverResponse: NTPResponse?
    let startTime: ntp_time_t?
    let sampleSize: Int?
    let pool: NSURL?

    init(time: NSDate, uptime: timeval) {
        self.init(time: time, uptime: uptime, serverResponse: nil, startTime: nil)
    }

    init(time: NSDate,
         uptime: timeval,
         serverResponse: NTPResponse?,
         startTime: ntp_time_t?,
         sampleSize: Int? = 0,
         pool: NSURL? = nil) {
        self.time = time
        self.uptime = uptime
        self.serverResponse = serverResponse
        self.startTime = startTime
        self.sampleSize = sampleSize
        self.pool = pool
    }

    init(referenceTime time: FrozenReferenceTime, sampleSize: Int, pool: NSURL) {
        self.init(time: time.time,
                  uptime: time.uptime,
                  serverResponse: time.serverResponse,
                  startTime: time.startTime,
                  sampleSize: sampleSize,
                  pool: pool)
    }

    func now() -> NSDate {
        return time.dateByAddingTimeInterval(uptimeInterval)
    }
}

extension ReferenceTimeContainer {
    var uptimeInterval: NSTimeInterval {
        let currentUptime = timeval.uptime()
        return NSTimeInterval(milliseconds: currentUptime.milliseconds - uptime.milliseconds)
    }

    var maxUptimeInterval: NSTimeInterval {
        return 1024
    }

    var shouldInvalidate: Bool {
        return uptimeInterval > maxUptimeInterval
    }
}
