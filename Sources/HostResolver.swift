//
//  HostResolver.swift
//  TrueTime
//
//  Created by Michael Sanders on 8/10/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import Result

typealias HostResult = Result<[SocketAddress], NSError>
typealias HostCallback = (HostResolver, HostResult) -> Void

final class HostResolver {
    let host: String
    let port: Int
    let timeout: TimeInterval
    let onComplete: HostCallback
    let callbackQueue: DispatchQueue
    var logger: LogCallback?

    /// Resolves the given hosts in order, returning the first resolved
    /// addresses or an error if none succeeded.
    ///
    /// - parameter hosts: Hosts to resolve
    /// - parameter timeout: duration after which to time out DNS resolution
    /// - parameter logger: logging callback for each host
    /// - parameter callbackQueue: queue to fire `onComplete` callback
    /// - parameter onComplete: invoked upon first successfully resolved host
    ///                         or when all hosts fail
    static func resolve(hosts: [(host: String, port: Int)],
                        timeout: TimeInterval,
                        logger: LogCallback?,
                        callbackQueue: DispatchQueue,
                        onComplete: @escaping HostCallback) {
        let host = HostResolver(host: hosts[0].host,
                                port: hosts[0].port,
                                timeout: timeout,
                                logger: logger,
                                callbackQueue: callbackQueue) { host, result in
            switch result {
            case .success,
                .failure where hosts.count == 1: onComplete(host, result)
            case .failure: resolve(hosts: Array(hosts.dropFirst()),
                                   timeout: timeout,
                                   logger: logger,
                                   callbackQueue: callbackQueue,
                                   onComplete: onComplete)
            }
        }

        host.resolve()
    }

    /// Resolves the given hosts in order, returning the first resolved
    /// addresses or an error if none succeeded.
    ///
    /// - parameter hosts: Host to resolve
    /// - parameter port: Port for the given host
    /// - parameter timeout: duration after which to time out DNS resolution
    /// - parameter logger: logging callback for each host
    /// - parameter callbackQueue: queue to fire `onComplete` callback
    /// - parameter onComplete: invoked upon completing or failing DNS resolution
    required init(host: String,
                  port: Int,
                  timeout: TimeInterval,
                  logger: LogCallback?,
                  callbackQueue: DispatchQueue,
                  onComplete: @escaping HostCallback) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.logger = logger
        self.onComplete = onComplete
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    /// Starts host resolution asynchronously for the given parameters.
    func resolve() {
        guard self.networkHost == nil else { return }
        let callback: CFHostClientCallBack = { host, hostinfo, error, info in
            guard let info = info else { return }
            let retainedSelf = Unmanaged<HostResolver>.fromOpaque(info)
            let resolver = retainedSelf.takeUnretainedValue()

            var resolved: DarwinBoolean = false
            let addressData = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [Data], resolved.boolValue else {
                resolver.complete(.failure(NSError(trueTimeError: .dnsLookupFailed)))
                return
            }

            let socketAddresses: [SocketAddress] = addresses.map { data -> SocketAddress? in
                let storage = (data as NSData).bytes.bindMemory(to: sockaddr_storage.self, capacity: data.count)
                return SocketAddress(storage: storage, port: UInt16(resolver.port))
            }.compactMap { $0 }

            resolver.debugLog("Resolved hosts: \(socketAddresses)")
            resolver.complete(.success(socketAddresses))
        }

        var clientContext = CFHostClientContext(version: 0,
                                                info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                                                retain: nil,
                                                release: nil,
                                                copyDescription: nil)

        let networkHost = CFHostCreateWithName(kCFAllocatorDefault, host as CFString).takeUnretainedValue()
        self.networkHost = networkHost
        timer = .scheduled(timeInterval: timeout) { [weak self] _ in
            self?.complete(.failure(.init(trueTimeError: .timedOut)))
        }
        CFHostSetClient(networkHost, callback, &clientContext)
        CFHostScheduleWithRunLoop(networkHost, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        CFHostStartInfoResolution(networkHost, .addresses, nil)
    }

    /// Stops host resolution.
    func stop() {
        timer?.cancel()
        timer = nil
        guard let networkHost = self.networkHost else { return }

        CFHostCancelInfoResolution(networkHost, .addresses)
        CFHostSetClient(networkHost, nil, nil)
        CFHostUnscheduleFromRunLoop(networkHost, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.networkHost = nil
        Unmanaged.passUnretained(self).release()
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    private var timer: DispatchBlockTimer?
    private var networkHost: CFHost?
}

private extension HostResolver {
    func complete(_ result: HostResult) {
        callbackQueue.async {
            self.onComplete(self, result)
        }
        stop()
    }
}
