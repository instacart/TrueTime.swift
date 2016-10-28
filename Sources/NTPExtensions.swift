//
//  NTPExtensions.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/10/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime

public extension timeval {
    static func uptime() -> timeval {
        let now = timeval.now()
        var boottime = timeval()
        var mib: [CInt] = [CTL_KERN, KERN_BOOTTIME]
        var size = strideofValue(boottime)
        withFatalErrno { sysctl(&mib, 2, &boottime, &size, nil, 0) }
        return timeval(tv_sec: now.tv_sec - boottime.tv_sec,
                       tv_usec: now.tv_usec - boottime.tv_usec)
    }

    var milliseconds: Int64 {
        return Int64(tv_sec) * Int64(MSEC_PER_SEC) + Int64(tv_usec) / Int64(USEC_PER_MSEC)
    }
}

extension timeval {
    static func now() -> timeval {
        var tv = timeval()
        withFatalErrno { gettimeofday(&tv, nil) }
        return tv
    }
}

// Represents an amount of time since the NTP epoch, January 1, 1900.
// https://en.wikipedia.org/wiki/Network_Time_Protocol#Timestamps
protocol NTPTimeType {
    associatedtype T: UnsignedIntegerType
    init(whole: T, fraction: T)
    var whole: T { get }
    var fraction: T { get }
}

protocol NTPTimevalConvertible: NTPTimeType {}

extension NTPTimeType {
    // Interprets the receiver as an elapsed time in milliseconds.
    var durationInMilliseconds: Int64 {
        return whole.toIntMax() * Int64(MSEC_PER_SEC) +
               fractionInMicroseconds / Int64(USEC_PER_MSEC)
    }

    var fractionInMicroseconds: Int64 {
        return fraction.toIntMax() / Int64(1<<32 / USEC_PER_SEC)
    }
}

extension NTPTimevalConvertible {
    init(timeSince1970 time: timeval) {
        precondition(time.tv_sec > 0 && time.tv_usec > 0, "Time must be positive \(time)")
        self.init(whole: T(UInt64(time.tv_sec + secondsFrom1900To1970)),
                  fraction: T(UInt64(time.tv_usec) * UInt64(1<<32 / USEC_PER_SEC)))
    }

    var milliseconds: Int64 {
        return (whole.toIntMax() - secondsFrom1900To1970) * Int64(MSEC_PER_SEC) +
                fractionInMicroseconds / Int64(USEC_PER_MSEC)
    }
}

extension ntp_time32_t: NTPTimeType {}
extension ntp_time64_t: NTPTimevalConvertible {}

extension NSTimeInterval {
    init(milliseconds: Int64) {
        self = Double(milliseconds) / Double(MSEC_PER_SEC)
    }

    init(_ timestamp: timeval) {
        self = Double(timestamp.tv_sec) + Double(timestamp.tv_usec) / Double(USEC_PER_SEC)
    }

    var dispatchTime: dispatch_time_t {
        return dispatch_time(DISPATCH_TIME_NOW, Int64(self * Double(NSEC_PER_SEC)))
    }

    var dispatchInterval: UInt64 {
        return UInt64(self * Double(NSEC_PER_SEC))
    }
}

protocol ByteRepresentable {
    init()
}

extension ByteRepresentable {
    var data: NSData {
        var buffer = self
        return NSData(bytes: &buffer, length: sizeofValue(buffer))
    }

    var isZero: Bool {
        var buffer = self
        let size = sizeofValue(buffer)
        let byteArray = withUnsafePointer(&buffer, UnsafePointer<UInt8>.init)
        return !(0..<size).contains { idx in byteArray[idx] > 0 }
    }
}

extension NSData {
    func decode<T: ByteRepresentable>() -> T {
        return UnsafePointer<T>(bytes).memory
    }
}

extension ntp_packet_t: ByteRepresentable {}
extension sockaddr_in: ByteRepresentable {}
extension sockaddr_in6: ByteRepresentable {}
extension sockaddr_in6: CustomStringConvertible {
    public var description: String {
        var buffer = [Int8](count: Int(INET6_ADDRSTRLEN), repeatedValue: 0)
        var addr = sin6_addr
        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))

        let host = String.fromCString(buffer) ?? ""
        let port = Int(sin6_port)
        return "\(host):\(port)"
    }
}

extension sockaddr_in: CustomStringConvertible {
    public var description: String {
        let host = String.fromCString(inet_ntoa(sin_addr)) ?? ""
        let port = Int(sin_port)
        return "\(host):\(port)"
    }
}

extension HostResolver: CustomStringConvertible {
    var description: String {
        return "\(self.dynamicType)(url: \(url), " +
                                   "timeout: \(timeout))"
    }
}

extension NTPConnection: CustomStringConvertible {
    var description: String {
        return "\(self.dynamicType)(socketAddress: \(address), " +
                                   "timeout: \(timeout), " +
                                   "maxRetries: \(maxRetries))"
    }
}

extension FrozenReferenceTime: CustomStringConvertible {
    var description: String {
        return "\(self.dynamicType)(time: \(time), uptime: \(uptime.milliseconds) ms)"
    }
}

extension FrozenReferenceTime: CustomDebugStringConvertible {
    var debugDescription: String {
        guard let serverResponse = serverResponse, startTime = startTime else {
            return description
        }

        let poolDescription = pool?.absoluteString ?? "nil"
        return "\(self.dynamicType)(time: " + time.description + ", " +
                                   "uptime: " + uptime.milliseconds.description + " ms, " +
                                   "serverResponse: " + serverResponse.description + ", " +
                                   "startTime: " + startTime.milliseconds.description + " ms, " +
                                   "sampleSize: " + (sampleSize ?? 0).description + ", " +
                                   "pool: " + poolDescription + ")"
    }
}

extension NTPResponse: CustomStringConvertible {
    var description: String {
        return "\(self.dynamicType)(packet: " + packet.description + ", " +
                                   "responseTime: " + responseTime.description + " ms, " +
                                   "receiveTime: " + receiveTime.milliseconds.description + " ms)"
    }
}

extension ntp_packet_t: CustomStringConvertible {
    // Avoid memory leak caused by long interpolated strings.
    // https://openradar.appspot.com/26366199
    public var description: String {
        let referenceTime = reference_time.milliseconds
        let originateTime = originate_time.milliseconds
        let receiveTime = receive_time.milliseconds
        let transmitTime = transmit_time.milliseconds
        return "\(self.dynamicType)(client_mode: " + client_mode.description + ", " +
                                   "version_number: " + version_number.description + ", " +
                                   "leap_indicator: " + leap_indicator.description + ", " +
                                   "stratum: " + stratum.description + ", " +
                                   "poll: " + poll.description + ", " +
                                   "precision: " + precision.description + ", " +
                                   "root_delay: " + String(root_delay) + ", " +
                                   "root_dispersion: " + String(root_dispersion) + ", " +
                                   "reference_id: " + String(reference_id) + ", " +
                                   "reference_time: " + referenceTime.description + " ms, " +
                                   "originate_time: " + originateTime.description + " ms, " +
                                   "receive_time: " + receiveTime.description + " ms, " +
                                   "transmit_time: " + transmitTime.description + " ms)"
    }
}

extension ntp_packet_t {
    var timeDescription: String {
        return "\(self.dynamicType)(reference_time: + \(reference_time.milliseconds) ms, " +
                                   "originate_time: \(originate_time.milliseconds) ms, " +
                                   "receive_time: \(receive_time.milliseconds) ms, " +
                                   "transmit_time: \(transmit_time.milliseconds) ms)"
    }
}

extension String {
    var localized: String {
        return NSBundle.mainBundle().localizedStringForKey(self, value: "", table: "TrueTime")
    }
}

extension TrueTimeError: CustomStringConvertible {
    public var description: String {
        switch self {
            case CannotFindHost:
                return "The connection failed because the host could not be found.".localized
            case DNSLookupFailed:
                return "The connection failed because the DNS lookup failed.".localized
            case TimedOut:
                return "The connection timed out.".localized
            case Offline:
                return "The connection failed because the device is not connected to the " +
                       "internet.".localized
            case BadServerResponse:
                return "The connection received an invalid server response.".localized
            case NoValidPacket:
                return "No valid NTP packet was found.".localized
        }
    }
}

extension NSError {
    convenience init(errno code: Int32) {
        var userInfo: [String: AnyObject]?
        if let description = String(UTF8String: strerror(code)) {
            userInfo = [NSLocalizedDescriptionKey: description]
        }
        self.init(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: userInfo)
    }

    convenience init(trueTimeError: TrueTimeError) {
        self.init(domain: TrueTimeErrorDomain, code: trueTimeError.rawValue, userInfo: [
            NSLocalizedDescriptionKey: trueTimeError.description
        ])
    }
}

extension dispatch_source_t {
    func cancel() {
        dispatch_source_cancel(self)
    }
}

// Can't add as static method to dispatch_source_t, as it's defined as a protocol.
func dispatchTimer(after interval: NSTimeInterval,
                   repeating: Bool = false,
                   queue: dispatch_queue_t,
                   block: dispatch_block_t) -> dispatch_source_t? {
    precondition(interval >= 0, "Interval must be >= 0 \(interval)")
    let timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue)
    dispatch_source_set_timer(timer,
                              interval.dispatchTime,
                              !repeating ? DISPATCH_TIME_FOREVER : interval.dispatchInterval,
                              NSEC_PER_SEC / 10)
    dispatch_source_set_event_handler(timer, block)
    dispatch_resume(timer)
    return timer
}

func withErrno<X: SignedIntegerType>(@noescape block: () -> X) throws -> X {
    let result = block()
    if result < 0 {
        throw NSError(errno: errno)
    }
    return result
}

// Equivalent to `withErrno` but asserts at runtime.
// Useful when `errno` can only be used to indicate programmer error.
func withFatalErrno<X: SignedIntegerType>(@noescape block: () -> X) -> X {
    // swiftlint:disable force_try
    return try! withErrno(block)
    // swiftlint:enable force_try
}

// Number of seconds between Jan 1, 1900 and Jan 1, 1970
// 70 years plus 17 leap days
private let secondsFrom1900To1970: Int64 = ((365 * 70) + 17) * 24 * 60 * 60

// swiftlint:disable variable_name
let MSEC_PER_SEC: UInt64 = 1000
let USEC_PER_MSEC: UInt64 = 1000
// swiftlint:enable variable_name
