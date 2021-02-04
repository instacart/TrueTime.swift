//
//  FrozenReferenceTime.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/26/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime

typealias FrozenTimeResult = Result<FrozenTime, NSError>
typealias FrozenTimeCallback = (FrozenTimeResult) -> Void

typealias FrozenNetworkTimeResult = Result<FrozenNetworkTime, NSError>
typealias FrozenNetworkTimeCallback = (FrozenNetworkTimeResult) -> Void

protocol FrozenTime {
    var time: Date { get }
    var uptime: timeval { get }
}

struct FrozenReferenceTime: FrozenTime {
    let time: Date
    let uptime: timeval
}

struct FrozenNetworkTime: FrozenTime {
    let time: Date
    let uptime: timeval
    let serverResponse: NTPResponse
    let startTime: ntp_time_t
    let sampleSize: Int?
    let host: String?

    init(time: Date,
         uptime: timeval,
         serverResponse: NTPResponse,
         startTime: ntp_time_t,
         sampleSize: Int? = 0,
         host: String? = nil) {
        self.time = time
        self.uptime = uptime
        self.serverResponse = serverResponse
        self.startTime = startTime
        self.sampleSize = sampleSize
        self.host = host
    }

    init(networkTime time: FrozenNetworkTime, sampleSize: Int, host: String) {
        self.init(time: time.time,
                  uptime: time.uptime,
                  serverResponse: time.serverResponse,
                  startTime: time.startTime,
                  sampleSize: sampleSize,
                  host: host)
    }
}

extension FrozenTime {
    var uptimeInterval: TimeInterval {
        let currentUptime = timeval.uptime()
        return TimeInterval(milliseconds: currentUptime.milliseconds - uptime.milliseconds)
    }

    func now() -> Date {
        return time.addingTimeInterval(uptimeInterval)
    }
}
