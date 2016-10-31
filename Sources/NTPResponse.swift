//
//  NTPResponse.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/14/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Foundation

struct NTPResponse {
    let packet: ntp_packet_t
    let responseTime: Int64
    let receiveTime: timeval
    init?(packet: ntp_packet_t, responseTime: Int64, receiveTime: timeval = .now()) {
        self.packet = packet
        self.responseTime = responseTime
        self.receiveTime = receiveTime
        if !isValidResponse {
            return nil
        }
    }

    // See https://en.wikipedia.org/wiki/Network_Time_Protocol#Clock_synchronization_algorithm
    var offset: Int64 {
        let T = offsetValues
        return ((T[1] - T[0]) + (T[2] - T[3])) / 2
    }

    var delay: Int64 {
        let T = offsetValues
        return (T[3] - T[0]) - (T[2] - T[1])
    }

    var networkDate: NSDate {
        let interval = NSTimeInterval(milliseconds: responseTime + offset)
        return NSDate(timeIntervalSince1970: interval)
    }

    private let maxRootDispersion: Int64 = 100
    private let maxDelayDelta: Int64 = 100
    private let ntpModeServer: UInt8 = 4
    private let leapIndicatorUnknown: UInt8 = 3
}

func bestTime(fromResponses times: [[FrozenReferenceTime]]) -> FrozenReferenceTime? {
    let bestTimes = times.map { (serverTimes: [FrozenReferenceTime]) -> FrozenReferenceTime? in
        serverTimes.minElement { $0.serverResponse?.delay < $1.serverResponse?.delay }
    }.filter { $0 != nil }.flatMap { $0 }.sort {
        $0.serverResponse?.offset < $1.serverResponse?.offset
    }

    return bestTimes.isEmpty ? nil : bestTimes[bestTimes.count / 2]
}

private extension NTPResponse {
    var isValidResponse: Bool {
        return !packet.isZero &&
                packet.root_delay.durationInMilliseconds < maxRootDispersion &&
                packet.root_dispersion.durationInMilliseconds < maxRootDispersion &&
                packet.client_mode == ntpModeServer &&
                packet.stratum > 0 && packet.stratum < 16 &&
                packet.leap_indicator != leapIndicatorUnknown &&
                abs(receiveTime.milliseconds -
                    packet.originate_time.milliseconds -
                    delay) < maxDelayDelta
    }

    var offsetValues: [Int64] {
        return [packet.originate_time.milliseconds,
                packet.receive_time.milliseconds,
                packet.transmit_time.milliseconds,
                responseTime]
    }
}
