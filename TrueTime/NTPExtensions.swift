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
        var size = sizeofValue(boottime)
        withFatalErrno { sysctl(&mib, 2, &boottime, &size, nil, 0) }
        return timeval(tv_sec: now.tv_sec - boottime.tv_sec,
                       tv_usec: now.tv_usec - boottime.tv_usec)
    }
}

extension timeval {
    static func now() -> timeval {
        var tv = timeval()
        withFatalErrno { gettimeofday(&tv, nil) }
        return tv
    }

    var milliseconds: Int64 {
        return Int64(tv_sec) * Int64(MSEC_PER_SEC) + Int64(tv_usec) / Int64(USEC_PER_MSEC)
    }
}

extension ntp_time_t {
    init(_ time: timeval) {
        precondition(time.tv_sec > 0 && time.tv_usec > 0, "Time must be positive \(time)")
        self.init(whole: UInt32(time.tv_sec + secondsFrom1900To1970),
                  // Fractions are 2^32 / second.
                  // https://en.wikipedia.org/wiki/Network_Time_Protocol#Timestamps
                  fraction: UInt32(UInt32(time.tv_usec) * UInt32(1<<32 / USEC_PER_SEC)))
    }

    // Milliseconds since epoch.
    var milliseconds: Int64 {
        return (Int64(whole) - secondsFrom1900To1970) * Int64(MSEC_PER_SEC) +
                usec / Int64(USEC_PER_MSEC)
    }

    // Fraction converted to microseconds.
    var usec: Int64 {
        return Int64(fraction) / Int64(1<<32 / USEC_PER_SEC)
    }
}

extension NSTimeInterval {
    init(milliseconds: Int64) {
        self = Double(milliseconds) / Double(MSEC_PER_SEC)
    }

    init(_ timestamp: timeval) {
        self = Double(timestamp.tv_sec) + Double(timestamp.tv_usec) / Double(USEC_PER_SEC)
    }

    init(_ timestamp: ntp_time_t) {
        self = Double(timestamp.whole) - Double(secondsFrom1900To1970) +
               Double(timestamp.usec) / Double(USEC_PER_SEC)
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
}

extension NSData {
    func decode<T: ByteRepresentable>() -> T {
        var value = T()
        getBytes(&value, length: sizeofValue(value))
        return value
    }
}

extension ntp_packet_t: ByteRepresentable {}
extension sockaddr_in: ByteRepresentable {}
extension sockaddr_in: CustomStringConvertible {
    public var description: String {
        let host = String(UTF8String: inet_ntoa(sin_addr)) ?? ""
        let port = Int(sin_port)
        return "\(host):\(port)"
    }
}

extension ReferenceTime: CustomStringConvertible {
    public var description: String {
        return "\(self.dynamicType)(time: \(time), uptime: \(uptime.milliseconds) ms)"
    }
}

extension ntp_packet_t {
    var timeDescription: String {
        return "\(self.dynamicType)(reference_time: \(reference_time.milliseconds) ms, " +
                                    "originate_time: \(originate_time.milliseconds) ms, " +
                                    "receive_time: \(receive_time.milliseconds) ms, " +
                                    "transmit_time: \(transmit_time.milliseconds) ms)"
    }
}

extension NSError {
    convenience init(errno: Int32) {
        var userInfo: [String: AnyObject]?
        if let description = String(UTF8String: strerror(errno)) {
            userInfo = [NSLocalizedDescriptionKey: description]
        }
        self.init(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: userInfo)
    }

    static var offlineError: NSError {
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
        ])
    }
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

#if DEBUG
func debugLog(@autoclosure message: () -> String) { print(message()) }
#else
func debugLog(@autoclosure message: () -> String) {}
#endif

// Number of seconds between Jan 1, 1900 and Jan 1, 1970
// 70 years plus 17 leap days
private let secondsFrom1900To1970: Int64 = ((365 * 70) + 17) * 24 * 60 * 60

// swiftlint:disable variable_name
private let MSEC_PER_SEC: UInt64 = 1000
private let USEC_PER_MSEC: UInt64 = 1000
// swiftlint:enable variable_name
