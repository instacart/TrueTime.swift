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
    let url: NSURL
    let timeout: NSTimeInterval
    let onComplete: HostCallback
    let callbackQueue: dispatch_queue_t
    var logger: LogCallback?

    /// Resolves the given hosts in order, returning the first resolved
    /// addresses or an error if none succeeded.
    ///
    /// - parameter urls: URLs to resolve
    /// - parameter timeout: duration after which to time out DNS resolution
    /// - parameter logger: logging callback for each host
    /// - parameter callbackQueue: queue to fire `onComplete` callback
    /// - parameter onComplete: invoked upon first successfully resolved host
    ///                         or when all hosts fail
    static func resolve(urls urls: [NSURL],
                        timeout: NSTimeInterval,
                        logger: LogCallback?,
                        callbackQueue: dispatch_queue_t,
                        onComplete: HostCallback) {
        precondition(!urls.isEmpty, "Must include at least one URL")
        let host = HostResolver(url: urls[0],
                                timeout: timeout,
                                logger: logger,
                                callbackQueue: callbackQueue) { host, result in
            switch result {
                case .Success: fallthrough
                case .Failure where urls.count == 1:
                    onComplete(host, result)
                case .Failure:
                    resolve(urls: Array(urls.dropFirst()),
                            timeout: timeout,
                            logger: logger,
                            callbackQueue: callbackQueue,
                            onComplete: onComplete)
            }
        }

        host.resolve()
    }

    required init(url: NSURL,
                  timeout: NSTimeInterval,
                  logger: LogCallback?,
                  callbackQueue: dispatch_queue_t,
                  onComplete: HostCallback) {
        self.url = url
        self.timeout = timeout
        self.logger = logger
        self.onComplete = onComplete
        self.callbackQueue = callbackQueue
    }

    deinit {
        assert(!self.started, "Unclosed host")
    }

    func resolve() {
        dispatch_async(lockQueue) {
            guard self.host == nil else { return }
            self.resolved = false
            self.host = CFHostCreateWithName(nil, self.url.absoluteString!).takeRetainedValue()
            var ctx = CFHostClientContext(
                version: 0,
                info: UnsafeMutablePointer(Unmanaged.passRetained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            if let host = self.host {
                CFHostSetClient(host, self.hostCallback, &ctx)
                CFHostScheduleWithRunLoop(host, CFRunLoopGetMain(), kCFRunLoopCommonModes)

                var err: CFStreamError = CFStreamError()
                if !CFHostStartInfoResolution(host, .Addresses, &err) {
                    self.complete(.Failure(NSError(trueTimeError: .CannotFindHost)))
                } else {
                    self.startTimer()
                }
            }
        }
    }

    func stop(waitUntilFinished wait: Bool = false) {
        let fn = wait ? dispatch_sync : dispatch_async
        fn(lockQueue) {
            self.cancelTimer()
            guard let host = self.host else { return }
            CFHostCancelInfoResolution(host, .Addresses)
            CFHostSetClient(host, nil, nil)
            CFHostUnscheduleFromRunLoop(host, CFRunLoopGetMain(), kCFRunLoopCommonModes)
            self.host = nil
        }
    }

    func debugLog(@autoclosure message: () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    var timer: dispatch_source_t?
    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.dns.host", nil)
    private var host: CFHost?
    private var resolved: Bool = false
    private let hostCallback: CFHostClientCallBack = { host, infoType, error, info in
        guard info != nil else { return }
        let retainedClient = Unmanaged<HostResolver>.fromOpaque(COpaquePointer(info))
        let client = retainedClient.takeUnretainedValue()
        client.connect(host)
        retainedClient.release()
    }
}

extension HostResolver: TimedOperation {
    var timerQueue: dispatch_queue_t { return lockQueue }
    var started: Bool { return self.host != nil }

    func timeoutError(error: NSError) {
        complete(.Failure(error))
    }
}

private extension HostResolver {
    func complete(result: HostResult) {
        stop()
        dispatch_async(callbackQueue) {
            self.onComplete(self, result)
        }
    }

    func connect(host: CFHost) {
        debugLog("Got CFHostStartInfoResolution callback")
        dispatch_async(lockQueue) {
            guard self.started && !self.resolved else {
                self.debugLog("Closed")
                return
            }

            var resolved: DarwinBoolean = false
            let addressData = CFHostGetAddressing(host,
                                                  &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [NSData] where resolved else {
                self.complete(.Failure(NSError(trueTimeError: .DNSLookupFailed)))
                return
            }

            let port = self.url.port?.integerValue ?? defaultNTPPort
            let socketAddresses = addresses.map { data -> SocketAddress? in
                let storage = UnsafePointer<sockaddr_storage>(data.bytes)
                return SocketAddress(storage: storage, port: UInt16(port))
            }.filter { $0 != nil }.flatMap { $0 }

            self.resolved = true
            self.debugLog("Resolved hosts: \(socketAddresses)")
            self.complete(.Success(socketAddresses))
        }
    }
}

private let defaultNTPPort: Int = 123
