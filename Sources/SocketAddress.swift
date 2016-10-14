//
//  SocketAddress.swift
//  TrueTime
//
//  Created by Michael Sanders on 9/14/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

enum SocketAddress {
    case IPv4(sockaddr_in)
    case IPv6(sockaddr_in6)

    init?(storage: UnsafePointer<sockaddr_storage>, port: UInt16? = nil) {
        guard storage != nil else {
            return nil
        }

        switch Int32(storage.memory.ss_family) {
            case AF_INET:
                let addrPointer = UnsafeMutablePointer<sockaddr_in>(storage)
                var addr = addrPointer.memory.nativeEndian
                addr.sin_port = port ?? addr.sin_port
                self = IPv4(addr)
            case AF_INET6:
                let addrPointer = UnsafeMutablePointer<sockaddr_in6>(storage)
                var addr = addrPointer.memory.nativeEndian
                addr.sin6_port = port ?? addr.sin6_port
                self = IPv6(addr)
            default:
                return nil
        }
    }

    var family: Int32 {
        switch self {
            case .IPv4:
                return PF_INET
            case .IPv6:
                return PF_INET6
        }
    }

    var networkData: NSData {
        switch self {
            case IPv4(let address):
                return address.bigEndian.data
            case IPv6(let address):
                return address.bigEndian.data
        }
    }

    var host: String {
        switch self {
            case IPv4(let address):
                return address.description
            case IPv6(let address):
                return address.description
        }
    }
}

extension SocketAddress: CustomStringConvertible {
    var description: String {
        return host
    }
}

extension SocketAddress: Hashable {
    var hashValue: Int {
        return host.hashValue
    }
}

func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
    return lhs.host == rhs.host
}
