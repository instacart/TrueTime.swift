//
//  Reachability.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/21/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import SystemConfiguration

enum ReachabilityStatus {
    case notReachable
    case reachableViaWWAN
    case reachableViaWiFi
}

final class Reachability {
    var callback: ((ReachabilityStatus) -> Void)?
    var callbackQueue: DispatchQueue = .main
    var status: ReachabilityStatus? {
        if let networkReachability = self.networkReachability {
            var flags = SCNetworkReachabilityFlags()
            if SCNetworkReachabilityGetFlags(networkReachability, &flags) {
                return ReachabilityStatus(flags)
            }
        }
        return nil
    }
    var online: Bool {
        return status != nil && status != .notReachable
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
        address.sin_family = sa_family_t(AF_INET)
        networkReachability = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr>.size) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }

        guard let networkReachability = networkReachability else {
            assertionFailure("SCNetworkReachabilityCreateWithAddress returned NULL")
            return
        }

        var context = SCNetworkReachabilityContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        SCNetworkReachabilitySetCallback(networkReachability, Reachability.reachabilityCallback, &context)
        SCNetworkReachabilitySetDispatchQueue(networkReachability, .global())

        if let status = status {
            updateStatus(status)
        }
    }

    func stopMonitoring() {
        if let networkReachability = networkReachability {
            SCNetworkReachabilitySetCallback(networkReachability, nil, nil)
            SCNetworkReachabilitySetDispatchQueue(networkReachability, nil)
            self.networkReachability = nil
        }
    }

    private var networkReachability: SCNetworkReachability?
    private static let reachabilityCallback: SCNetworkReachabilityCallBack = { _, flags, info in
        guard let info = info else { return }
        let reachability = Unmanaged<Reachability>.fromOpaque(info).takeUnretainedValue()
        reachability.updateStatus(ReachabilityStatus(flags))
    }
}

private extension Reachability {
    func updateStatus(_ status: ReachabilityStatus) {
        callbackQueue.async {
            self.callback?(status)
        }
    }
}

private extension ReachabilityStatus {
    init(_ flags: SCNetworkReachabilityFlags) {
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let connectsAutomatically = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
        let connectsWithoutInteraction = connectsAutomatically && !flags.contains(.interventionRequired)
        let isNetworkReachable = isReachable && (!needsConnection || connectsWithoutInteraction)
        if !isNetworkReachable {
            self = .notReachable
        } else {
#if os(iOS)
            if flags.contains(.isWWAN) {
                self = .reachableViaWWAN
                return
            }
#endif
            self = .reachableViaWiFi
        }
    }
}
