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
    let url: URL
    let timeout: TimeInterval
    let onComplete: HostCallback
    let callbackQueue: DispatchQueue
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
    static func resolve(urls: [URL],
                        timeout: TimeInterval,
                        logger: LogCallback?,
                        callbackQueue: DispatchQueue,
                        onComplete: @escaping HostCallback) {
        precondition(!urls.isEmpty, "Must include at least one URL")
        let host = HostResolver(url: urls[0],
                                timeout: timeout,
                                logger: logger,
                                callbackQueue: callbackQueue) { host, result in
            switch result {
                case .success: fallthrough
                case .failure where urls.count == 1:
                    onComplete(host, result)
                case .failure:
                    resolve(urls: Array(urls.dropFirst()),
                            timeout: timeout,
                            logger: logger,
                            callbackQueue: callbackQueue,
                            onComplete: onComplete)
            }
        }

        host.resolve()
    }

    required init(url: URL,
                  timeout: TimeInterval,
                  logger: LogCallback?,
                  callbackQueue: DispatchQueue,
                  onComplete: @escaping HostCallback) {
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
        lockQueue.async {
            guard self.host == nil else { return }
            self.resolved = false
            self.host = CFHostCreateWithName(
                nil,
                self.url.absoluteString as CFString
            ).takeRetainedValue()
            var ctx = CFHostClientContext(
                version: 0,
                info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            if let host = self.host {
                CFHostSetClient(host, self.hostCallback, &ctx)
                CFHostScheduleWithRunLoop(host,
                                          CFRunLoopGetMain(),
                                          CFRunLoopMode.commonModes.rawValue)

                var err: CFStreamError = CFStreamError()
                if !CFHostStartInfoResolution(host, .addresses, &err) {
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
            guard let host = self.host else { return }
            CFHostCancelInfoResolution(host, .addresses)
            CFHostSetClient(host, nil, nil)
            CFHostUnscheduleFromRunLoop(host,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)
            self.host = nil
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
    fileprivate var host: CFHost?
    fileprivate var resolved: Bool = false
    private let hostCallback: CFHostClientCallBack = { host, infoType, error, info in
        guard let info = info else { return }
        let retainedClient = Unmanaged<HostResolver>.fromOpaque(info)
        let client = retainedClient.takeUnretainedValue()
        client.connect(host)
        retainedClient.release()
    }
}

extension HostResolver: TimedOperation {
    var timerQueue: DispatchQueue { return lockQueue }
    var started: Bool { return self.host != nil }

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
            let addressData = CFHostGetAddressing(host,
                                                  &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [Data], resolved.boolValue else {
                self.complete(.failure(NSError(trueTimeError: .dnsLookupFailed)))
                return
            }

            let port = self.url.port ?? defaultNTPPort
            let socketAddresses = addresses.map { data -> SocketAddress? in
                let storage = (data as NSData).bytes.bindMemory(to: sockaddr_storage.self,
                                                                capacity: data.count)
                return SocketAddress(storage: storage, port: UInt16(port))
            }.flatMap { $0 }

            self.resolved = true
            self.debugLog("Resolved hosts: \(socketAddresses)")
            self.complete(.success(socketAddresses))
        }
    }
}

private let defaultNTPPort: Int = 123
