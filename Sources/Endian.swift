//
//  Endian.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/11/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime

protocol NetworkOrderConvertible {
    var byteSwapped: Self { get }
}

extension NetworkOrderConvertible {
    var bigEndian: Self {
        return isLittleEndian ? byteSwapped : self
    }

    var littleEndian: Self {
        return isLittleEndian ? self : byteSwapped
    }

    /// Returns the native representation converted from big-endian, changing
    /// the byte order if necessary.
    var nativeEndian: Self {
        return isLittleEndian ? byteSwapped : self
    }
}

extension Int: NetworkOrderConvertible {}
extension ntp_time32_t: NetworkOrderConvertible {
    var byteSwapped: ntp_time32_t {
        return ntp_time32_t(whole: whole.byteSwapped, fraction: fraction.byteSwapped)
    }
}

extension ntp_time64_t: NetworkOrderConvertible {
    var byteSwapped: ntp_time64_t {
        return ntp_time64_t(whole: whole.byteSwapped, fraction: fraction.byteSwapped)
    }
}

extension ntp_packet_t: NetworkOrderConvertible {
    var byteSwapped: ntp_packet_t {
        return ntp_packet_t(client_mode: client_mode,
                            version_number: version_number,
                            leap_indicator: leap_indicator,
                            stratum: stratum,
                            poll: poll,
                            precision: precision,
                            root_delay: root_delay.byteSwapped,
                            root_dispersion: root_dispersion.byteSwapped,
                            reference_id: reference_id,
                            reference_time: reference_time.byteSwapped,
                            originate_time: originate_time.byteSwapped,
                            receive_time: receive_time.byteSwapped,
                            transmit_time: transmit_time.byteSwapped)
    }
}

extension sockaddr_in6: NetworkOrderConvertible {
    var byteSwapped: sockaddr_in6 {
        return sockaddr_in6(sin6_len: sin6_len,
                            sin6_family: sin6_family,
                            sin6_port: sin6_port.byteSwapped,
                            sin6_flowinfo: sin6_flowinfo.byteSwapped,
                            sin6_addr: sin6_addr,
                            sin6_scope_id: sin6_scope_id.byteSwapped)
    }
}

extension sockaddr_in: NetworkOrderConvertible {
    var byteSwapped: sockaddr_in {
        return sockaddr_in(sin_len: sin_len,
                           sin_family: sin_family,
                           sin_port: sin_port.byteSwapped,
                           sin_addr: in_addr(s_addr: sin_addr.s_addr.byteSwapped),
                           sin_zero: sin_zero)
    }
}

private enum ByteOrder {
    static let BigEndian = CFByteOrder(CFByteOrderBigEndian.rawValue)
    static let LittleEndian = CFByteOrder(CFByteOrderLittleEndian.rawValue)
    static let Unknown = CFByteOrder(CFByteOrderUnknown.rawValue)
}

private let isLittleEndian = CFByteOrderGetCurrent() == ByteOrder.LittleEndian
