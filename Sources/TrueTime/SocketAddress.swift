//
//  SocketAddress.swift
//  TrueTime
//
//  Created by Michael Sanders on 9/14/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

enum SocketAddress {
    case iPv4(sockaddr_in)
    case iPv6(sockaddr_in6)

    init?(storage: UnsafePointer<sockaddr_storage>, port: UInt16? = nil) {
        switch Int32(storage.pointee.ss_family) {
        case AF_INET:
            self = storage.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var addr = pointer.pointee.nativeEndian
                addr.sin_port = port ?? addr.sin_port
                return .iPv4(addr)
            }
        case AF_INET6:
            self = storage.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var addr = pointer.pointee.nativeEndian
                addr.sin6_port = port ?? addr.sin6_port
                return .iPv6(addr)
            }
        default: return nil
        }
    }

    var family: Int32 {
        switch self {
        case .iPv4: return PF_INET
        case .iPv6: return PF_INET6
        }
    }

    var networkData: Data {
        switch self {
        case .iPv4(let address): return address.bigEndian.data as Data
        case .iPv6(let address): return address.bigEndian.data as Data
        }
    }

    var host: String {
        switch self {
        case .iPv4(let address): return address.description
        case .iPv6(let address): return address.description
        }
    }
}

extension SocketAddress: CustomStringConvertible {
    var description: String {
        return host
    }
}

extension SocketAddress: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(host.hashValue)
    }
}

func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
    return lhs.host == rhs.host
}
