//
//  NTPResponse.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/14/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime

struct NTPResponse {
    let packet: ntp_packet_t
    let responseTime: Int64
    let receiveTime: timeval
    init?(packet: ntp_packet_t, responseTime: Int64, receiveTime: timeval = .now()) {
        self.packet = packet
        self.responseTime = responseTime
        self.receiveTime = receiveTime
        guard isValidResponse else { return nil }
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

    var networkDate: Date {
        let interval = TimeInterval(milliseconds: responseTime + offset)
        return Date(timeIntervalSince1970: interval)
    }
}

func bestTime(fromResponses times: [[FrozenNetworkTime]]) -> FrozenNetworkTime? {
    let bestTimes = times.map { serverTimes -> FrozenNetworkTime? in
        serverTimes.min { $0.serverResponse.delay < $1.serverResponse.delay }
    }.compactMap { $0 }.sorted { $0.serverResponse.offset < $1.serverResponse.offset }

    return bestTimes.isEmpty ? nil : bestTimes[bestTimes.count / 2]
}

private extension NTPResponse {
    var isValidResponse: Bool {
        return packet.stratum > 0 && packet.stratum < 16 &&
               packet.root_delay.durationInMilliseconds < maxRootDispersion &&
               packet.root_dispersion.durationInMilliseconds < maxRootDispersion &&
               packet.client_mode == ntpModeServer &&
               packet.leap_indicator != leapIndicatorUnknown &&
               abs(receiveTime.milliseconds - packet.originate_time.milliseconds - delay) < maxDelayDelta
    }

    var offsetValues: [Int64] {
        return [packet.originate_time.milliseconds,
                packet.receive_time.milliseconds,
                packet.transmit_time.milliseconds,
                responseTime]
    }
}

private let maxRootDispersion: Int64 = 100
private let maxDelayDelta: Int64 = 100
private let ntpModeServer: UInt8 = 4
private let leapIndicatorUnknown: UInt8 = 3
