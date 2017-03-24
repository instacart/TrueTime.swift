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
    case NotReachable
    case ReachableViaWWAN
    case ReachableViaWiFi
}

final class Reachability {
    var callback: (ReachabilityStatus -> Void)?
    var callbackQueue: dispatch_queue_t = dispatch_get_main_queue()
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
        return status != nil && status != .NotReachable
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        var address = sockaddr_in()
        address.sin_len = UInt8(sizeofValue(address))
        address.sin_family = sa_family_t(AF_INET)
        self.networkReachability = withUnsafePointer(&address) {
            SCNetworkReachabilityCreateWithAddress(nil, UnsafePointer($0))
        }

        guard let networkReachability = self.networkReachability else {
            assertionFailure("SCNetworkReachabilityCreateWithAddress returned NULL")
            return
        }

        var context = SCNetworkReachabilityContext(
            version: 0,
            info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        SCNetworkReachabilitySetCallback(networkReachability,
                                         self.dynamicType.reachabilityCallback,
                                         &context)
        SCNetworkReachabilitySetDispatchQueue(networkReachability, dispatch_get_global_queue(0, 0))

        if let status = self.status {
            self.updateStatus(status)
        }
    }

    func stopMonitoring() {
        if let networkReachability = self.networkReachability {
            SCNetworkReachabilitySetCallback(networkReachability, nil, nil)
            SCNetworkReachabilitySetDispatchQueue(networkReachability, nil)
        }
        self.networkReachability = nil
    }

    private var networkReachability: SCNetworkReachabilityRef?
    private static let reachabilityCallback: SCNetworkReachabilityCallBack = { (_, flags, info) in
        let reachability = Unmanaged<Reachability>.fromOpaque(COpaquePointer(info))
                                                  .takeUnretainedValue()
        reachability.updateStatus(ReachabilityStatus(flags))
    }
}

private extension Reachability {
    func updateStatus(status: ReachabilityStatus) {
        dispatch_async(callbackQueue) {
            self.callback?(status)
        }
    }
}

private extension ReachabilityStatus {
    init(_ flags: SCNetworkReachabilityFlags) {
        let isReachable = flags.contains(.Reachable)
        let needsConnection = flags.contains(.ConnectionRequired)
        let connectsAutomatically = flags.contains(.ConnectionOnDemand) ||
                                    flags.contains(.ConnectionOnTraffic)
        let connectsWithoutInteraction = connectsAutomatically &&
                                         !flags.contains(.InterventionRequired)
        let isNetworkReachable = isReachable && (!needsConnection || connectsWithoutInteraction)
        if !isNetworkReachable {
            self = NotReachable
        } else {
#if os(iOS)
            if flags.contains(.IsWWAN) {
                self = ReachableViaWWAN
                return
            }
#endif
            self = ReachableViaWiFi
        }
    }
}
