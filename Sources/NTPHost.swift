//
//  NTPHost.swift
//  TrueTime
//
//  Created by Michael Sanders on 8/10/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import Result

typealias SNTPHostResult = Result<[SNTPConnection], NSError>
typealias SNTPHostCallback = SNTPHostResult -> Void

final class SNTPHost {
    let hostURL: NSURL
    let timeout: NSTimeInterval
    let onComplete: SNTPHostCallback
    let callbackQueue: dispatch_queue_t
    let maxRetries: Int

    required init(hostURL: NSURL,
                  timeout: NSTimeInterval,
                  maxRetries: Int,
                  onComplete: SNTPHostCallback,
                  callbackQueue: dispatch_queue_t) {
        self.hostURL = hostURL
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.onComplete = onComplete
        self.callbackQueue = callbackQueue
    }

    deinit {
        assert(!self.started, "Unclosed host")
    }

    var isStarted: Bool {
        var started: Bool = false
        dispatch_sync(lockQueue) {
            started = self.started
        }
        return started
    }

    var isResolved: Bool {
        var resolved: Bool = false
        dispatch_sync(lockQueue) {
            resolved = self.resolved
        }
        return resolved
    }

    var canRetry: Bool {
        var canRetry: Bool = false
        dispatch_sync(lockQueue) {
            canRetry = self.attempts < self.maxRetries && !self.didTimeout
        }
        return canRetry
    }

    func resolve() {
        dispatch_async(lockQueue) {
            guard self.host == nil else { return }
            self.resolved = false
            self.attempts += 1
            self.host = CFHostCreateWithName(nil, self.hostURL.absoluteString).takeRetainedValue()

            var ctx = CFHostClientContext(
                version: 0,
                info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: unsafeBitCast(0, CFAllocatorCopyDescriptionCallBack.self)
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

#if DEBUG_LOGGING
    func debugLog(@autoclosure message: () -> String) {
        logCallback?(message())
    }
#else
    func debugLog(@autoclosure message: () -> String) {}
#endif

    var logCallback: (String -> Void)?
    var timer: dispatch_source_t?
    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-host", nil)
    private var attempts: Int = 0
    private var didTimeout: Bool = false
    private var host: CFHost?
    private var resolved: Bool = false
    private let hostCallback: CFHostClientCallBack = { host, infoType, error, info in
        let client = Unmanaged<SNTPHost>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
        client.connect(host)
    }
}

extension SNTPHost: SNTPNode {
    var timerQueue: dispatch_queue_t { return lockQueue }
    var started: Bool { return self.host != nil }

    func timeoutError(error: NSError) {
        self.didTimeout = true
        complete(.Failure(error))
    }
}

private extension SNTPHost {
    func complete(result: SNTPHostResult) {
        stop()
        switch result {
            case let .Failure(error) where attempts < maxRetries && !didTimeout:
                debugLog("Got error from \(hostURL) (attempt \(attempts)), trying again. \(error)")
                resolve()
            case .Failure, .Success:
                dispatch_async(callbackQueue) {
                    self.onComplete(result)
                }
        }
    }

    func connect(host: CFHost) {
        debugLog("Got CFHostStartInfoResolution callback")
        dispatch_async(lockQueue) {
            guard self.host != nil && !self.resolved else {
                self.debugLog("Closed")
                return
            }

            var resolved: DarwinBoolean = false
            let port = self.hostURL.port?.integerValue ?? defaultNTPPort
            let addressData = CFHostGetAddressing(host,
                                                  &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [NSData] where resolved else {
                self.complete(.Failure(NSError(trueTimeError: .DNSLookupFailed)))
                return
            }

            let sockAddresses = addresses.map { data -> SocketAddress? in
                let storage = UnsafePointer<sockaddr_storage>(data.bytes)
                return SocketAddress(storage: storage, port: UInt16(port))
            }.filter { $0 != nil }.flatMap { $0 }

            self.debugLog("Resolved hosts: \(sockAddresses)")
            let connections = sockAddresses.map { SNTPConnection(socketAddress: $0,
                                                                 timeout: self.timeout,
                                                                 maxRetries: self.maxRetries) }
            self.resolved = true
            self.complete(.Success(connections))
        }
    }
}

private let defaultNTPPort: Int = 123
