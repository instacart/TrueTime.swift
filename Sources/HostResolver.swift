//
//  HostResolver.swift
//  TrueTime
//
//  Created by Michael Sanders on 8/10/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

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
    /// - parameter pool: Pool to resolve
    /// - parameter port: Port to use when resolving each pool
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
        precondition(!hosts.isEmpty, "Must include at least one URL")
        let host = HostResolver(host: hosts[0].host,
                                port: hosts[0].port,
                                timeout: timeout,
                                logger: logger,
                                callbackQueue: callbackQueue) { host, result in
            switch result {
            case .success,
                 .failure where hosts.count == 1: onComplete(host, result)
            case .failure:
                resolve(hosts: Array(hosts.dropFirst()),
                        timeout: timeout,
                        logger: logger,
                        callbackQueue: callbackQueue,
                        onComplete: onComplete)
            }
        }

        host.resolve()
    }

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
        assert(!self.started, "Unclosed host")
    }

    func resolve() {
        lockQueue.async {
            guard self.networkHost == nil else { return }
            self.resolved = false
            self.networkHost = CFHostCreateWithName(nil, self.host as CFString).takeRetainedValue()
            var ctx = CFHostClientContext(
                version: 0,
                info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            self.callbackPending = true

            if let networkHost = self.networkHost {
                CFHostSetClient(networkHost, self.hostCallback, &ctx)
                CFHostScheduleWithRunLoop(networkHost,
                                          CFRunLoopGetMain(),
                                          CFRunLoopMode.commonModes.rawValue)

                var err: CFStreamError = CFStreamError()
                if !CFHostStartInfoResolution(networkHost, .addresses, &err) {
                    self.complete(.failure(NSError(trueTimeError: .cannotFindHost)))
                } else {
                    self.startTimer()
                }
            }
        }
    }

    func stop(waitUntilFinished wait: Bool = false) {
        let work = {
            self.cancelTimer()
            if let networkHost = self.networkHost {
                CFHostCancelInfoResolution(networkHost, .addresses)
                CFHostSetClient(networkHost, nil, nil)
                CFHostUnscheduleFromRunLoop(networkHost, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                self.networkHost = nil
            }
            if self.callbackPending {
                Unmanaged.passUnretained(self).release()
                self.callbackPending = false
            }
        }

        if wait {
            lockQueue.sync(execute: work)
        } else {
            lockQueue.async(execute: work)
        }
    }

    func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    var timer: DispatchSourceTimer?
    fileprivate let lockQueue = DispatchQueue(label: "com.instacart.dns.host")
    fileprivate var networkHost: CFHost?
    fileprivate var resolved: Bool = false
    fileprivate var callbackPending: Bool = false
    private let hostCallback: CFHostClientCallBack = { host, infoType, error, info in
        guard let info = info else { return }
        let retainedClient = Unmanaged<HostResolver>.fromOpaque(info)
        let client = retainedClient.takeUnretainedValue()
        client.callbackPending = false
        client.connect(host)
        retainedClient.release()
    }
}

extension HostResolver: TimedOperation {
    var timerQueue: DispatchQueue { return lockQueue }
    var started: Bool { return self.networkHost != nil }

    func timeoutError(_ error: NSError) {
        complete(.failure(error))
    }
}

private extension HostResolver {
    func complete(_ result: HostResult) {
        stop()
        callbackQueue.async {
            self.onComplete(self, result)
        }
    }

    func connect(_ host: CFHost) {
        debugLog("Got CFHostStartInfoResolution callback")
        lockQueue.async {
            guard self.started && !self.resolved else {
                self.debugLog("Closed")
                return
            }

            var resolved: DarwinBoolean = false
            let addressData = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [Data], resolved.boolValue else {
                self.complete(.failure(NSError(trueTimeError: .dnsLookupFailed)))
                return
            }

            let socketAddresses = addresses.map { data -> SocketAddress? in
                let storage = (data as NSData).bytes.bindMemory(to: sockaddr_storage.self, capacity: data.count)
                return SocketAddress(storage: storage, port: UInt16(self.port))
            }.compactMap { $0 }

            self.resolved = true
            self.debugLog("Resolved hosts: \(socketAddresses)")
            self.complete(.success(socketAddresses))
        }
    }
}

private let defaultNTPPort: Int = 123
