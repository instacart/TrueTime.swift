//
//  NTPNode.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/18/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime
import Result

typealias SNTPHostResult = Result<[SNTPConnection], SNTPClientError>
typealias SNTPHostCallback = (SNTPHostResult) -> Void

private protocol SNTPNode: class {
    var timeout: NSTimeInterval { get }
    var started: Bool { get }
    var canRetry: Bool { get }
    var lockQueue: dispatch_queue_t { get }
    var timer: dispatch_source_t? { get set }
    func timeoutError(error: SNTPClientError)
}

extension SNTPNode {
    func startTimer() {
        cancelTimer()
        timer = dispatchTimer(after: timeout, queue: lockQueue) {
            guard self.started else { return }
            debugLog("Got timeout connecting to \(self)")
            self.timeoutError(.ConnectionError(underlyingError: .timeoutError))
        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

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
            canRetry = self.attempts < self.maxRetries && !self.didTimeOut
        }
        return canRetry
    }

    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-host", nil)
    private var attempts: Int = 0
    private var didTimeOut: Bool = false
    private var host: CFHost?
    private var resolved: Bool = false
    private var started: Bool { return self.host != nil }
    private var timer: dispatch_source_t?
    private static let hostCallback: CFHostClientCallBack = { (host, infoType, error, info)  in
        let client = Unmanaged<SNTPHost>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
        debugLog("Got CFHostStartInfoResolution callback")
        client.connect(host)
    }
}

extension SNTPHost {
    func resolve() {
        dispatch_async(lockQueue) {
            guard self.host == nil else { return }
            self.resolved = false
            self.attempts += 1
            self.host = CFHostCreateWithName(nil, self.hostURL.absoluteString).takeUnretainedValue()

            var ctx = CFHostClientContext(
                version: 0,
                info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: unsafeBitCast(0, CFAllocatorCopyDescriptionCallBack.self)
            )

            if let host = self.host {
                CFHostSetClient(host, self.dynamicType.hostCallback, &ctx)
                CFHostScheduleWithRunLoop(host, CFRunLoopGetMain(), kCFRunLoopCommonModes)

                var err: CFStreamError = CFStreamError()
                if !CFHostStartInfoResolution(host, .Addresses, &err) {
                    self.complete(.Failure(.UnresolvableHost(underlyingError: err)))
                } else {
                    self.startTimer()
                }
            }
        }
    }

    func stop() {
        dispatch_async(lockQueue) {
            self.cancelTimer()
            guard let host = self.host else { return }
            CFHostCancelInfoResolution(host, .Addresses)
            CFHostSetClient(host, nil, nil)
            CFHostUnscheduleFromRunLoop(host, CFRunLoopGetMain(), kCFRunLoopCommonModes)
            self.host = nil
        }
    }
}

extension SNTPHost: SNTPNode {
    func timeoutError(error: SNTPClientError) {
        self.didTimeOut = true
        complete(.Failure(error))
    }
}

private extension SNTPHost {
    func complete(result: SNTPHostResult) {
        stop()
        switch result {
            case let .Failure(error) where attempts < maxRetries && !didTimeOut:
                debugLog("Got error from \(hostURL) (attempt \(attempts)), trying " +
                         "again. \(error)")
                resolve()
            case .Failure, .Success:
                dispatch_async(callbackQueue) {
                    self.onComplete(result)
                }
        }
    }

    func connect(host: CFHost) {
        dispatch_async(lockQueue) {
            guard self.host != nil && !self.resolved else {
                debugLog("Closed")
                return
            }

            var resolved: DarwinBoolean = false
            let port = self.hostURL.port?.integerValue ?? defaultNTPPort
            let addressData = CFHostGetAddressing(host,
                                                  &resolved)?.takeUnretainedValue() as [AnyObject]?
            guard let addresses = addressData as? [NSData] where resolved else {
                self.complete(.Failure(.UnresolvableHost(underlyingError: nil)))
                return
            }

            let sockAddresses = addresses.map { data -> sockaddr_in in
                var addr = (data.decode() as sockaddr_in).nativeEndian
                addr.sin_port = UInt16(port)
                return addr
            }.filter { addr in addr.sin_addr.s_addr != 0 }

            debugLog("Resolved hosts: \(sockAddresses)")
            let connections = sockAddresses.map { SNTPConnection(socketAddress: $0,
                                                                 timeout: self.timeout,
                                                                 maxRetries: self.maxRetries) }
            self.resolved = true
            self.complete(.Success(connections))
        }
    }
}

final class SNTPConnection {
    let socketAddress: sockaddr_in
    let timeout: NSTimeInterval
    let maxRetries: Int

    required init(socketAddress: sockaddr_in, timeout: NSTimeInterval, maxRetries: Int) {
        self.socketAddress = socketAddress
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    var isStarted: Bool {
        var started: Bool = false
        dispatch_sync(lockQueue) {
            started = self.socket != nil
        }
        return started
    }

    var canRetry: Bool {
        var canRetry: Bool = false
        dispatch_sync(lockQueue) {
            canRetry = self.attempts < self.maxRetries && !self.didTimeOut
        }
        return canRetry
    }

    func start(callbackQueue: dispatch_queue_t, onComplete: ReferenceTimeCallback) {
        dispatch_async(lockQueue) {
            guard !self.started else { return }

            let callbackTypes: [CFSocketCallBackType] = [.DataCallBack, .WriteCallBack]
            var ctx = CFSocketContext(
                version: 0,
                info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: unsafeBitCast(0, CFAllocatorCopyDescriptionCallBack.self)
            )

            self.attempts += 1
            self.callbackQueue = callbackQueue
            self.onComplete = onComplete
            self.socket = CFSocketCreate(nil,
                                         PF_INET,
                                         SOCK_DGRAM,
                                         IPPROTO_UDP,
                                         callbackTypes.map { $0.rawValue }.reduce(0, combine: |),
                                         self.dynamicType.dataCallback,
                                         &ctx)

            if let socket = self.socket {
                let source = CFSocketCreateRunLoopSource(nil, socket, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes)
                self.startTimer()
            }
        }
    }

    func close() {
        dispatch_async(lockQueue) {
            guard let socket = self.socket else { return }
            debugLog("Connection closed \(self.socketAddress)")
            CFSocketInvalidate(socket)
            self.socket = nil
            self.cancelTimer()
        }
    }

    private static let dataCallback: CFSocketCallBack = { (socket, type, address, data, info)  in
        let client = Unmanaged<SNTPConnection>.fromOpaque(COpaquePointer(info))
                                              .takeUnretainedValue()
        guard let socket = socket where CFSocketIsValid(socket) else { return }

        // Can't use switch here as these aren't defined as an enum.
        if type == .DataCallBack {
            let data = Unmanaged<CFData>.fromOpaque(COpaquePointer(data)).takeUnretainedValue()
            client.handleResponse(data)
        } else if type == .WriteCallBack {
            debugLog("Buffer \(client.socketAddress) writable - requesting time")
            client.requestTime()
        } else {
            assertionFailure("Unexpected socket callback")
        }
    }

    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-connection",
                                                                    nil)
    private var attempts: Int = 0
    private var callbackQueue: dispatch_queue_t?
    private var didTimeOut: Bool = false
    private var onComplete: ReferenceTimeCallback?
    private var requestTicks: timeval?
    private var socket: CFSocket?
    private var startTime: timeval?
    private var started: Bool { return self.socket != nil }
    private var timer: dispatch_source_t?
}

extension SNTPConnection: SNTPNode {
    func timeoutError(error: SNTPClientError) {
        self.didTimeOut = true
        complete(.Failure(error))
    }
}
private extension SNTPConnection {
    func complete(result: ReferenceTimeResult) {
        guard let callbackQueue = callbackQueue, onComplete = onComplete else {
            assertionFailure("Completion callback not initialized")
            return
        }

        close()
        switch result {
            case let .Failure(error) where attempts < maxRetries && !didTimeOut:
                debugLog("Got error from \(socketAddress) (attempt \(attempts)), " +
                         "trying again. \(error)")
                start(callbackQueue, onComplete: onComplete)
            case .Failure, .Success:
                dispatch_async(callbackQueue) {
                    onComplete(result)
                }
        }
    }

    func requestTime() {
        dispatch_async(lockQueue) {
            guard let socket = self.socket else {
                debugLog("Socket closed")
                return
            }

            self.startTime = timeval.now()
            self.requestTicks = timeval.uptime()
            if let startTime = self.startTime {
                let time = ntp_time_t(startTime)
                let packet = self.requestPacket(time).bigEndian
                debugLog("Sending time: \(NSDate(timeIntervalSince1970: NSTimeInterval(time)))")
                let err = CFSocketSendData(socket,
                                           self.socketAddress.bigEndian.data,
                                           packet.data,
                                           self.timeout)
                if err != .Success {
                    let error = NSError(errno: errno)
                    self.complete(.Failure(.ConnectionError(underlyingError: error)))
                } else {
                    self.startTimer()
                }
            }
        }
    }

    func handleResponse(data: NSData) {
        let responseTicks = timeval.uptime()
        dispatch_async(lockQueue) {
            guard self.started else { return } // Socket closed.
            guard let startTime = self.startTime, requestTicks = self.requestTicks else {
                assertionFailure("Uninitialized timestamps")
                return
            }

            let packet = (data.decode() as ntp_packet_t).nativeEndian
            guard !packet.isZero else { // Guard against dropped packets.
                self.complete(.Failure(.InvalidResponse))
                return
            }

            let responseTime = startTime.milliseconds + (responseTicks.milliseconds -
                                                         requestTicks.milliseconds)

            // https://en.wikipedia.org/wiki/Network_Time_Protocol#Clock_synchronization_algorithm
            let T = [packet.originate_time.milliseconds,
                     packet.receive_time.milliseconds,
                     packet.transmit_time.milliseconds,
                     responseTime]
            let offset = ((T[1] - T[0]) + (T[2] - T[3])) / 2
            let delay = (T[3] - T[0]) - (T[2] - T[1])
            let interval = NSTimeInterval(milliseconds: responseTime + offset)
            let trueTime = NSDate(timeIntervalSince1970: interval)

            debugLog("Buffer \(self.socketAddress) has read data!")
            debugLog("Start time: \(startTime.milliseconds) ms, " +
                     "response: \(packet.timeDescription)")
            debugLog("Clock offset: \(offset) milliseconds")
            debugLog("Round-trip delay: \(delay) milliseconds")
            self.complete(.Success(ReferenceTime(time: trueTime,
                                                 uptime: responseTicks,
                                                 serverResponse: packet,
                                                 startTime: startTime)))
        }
    }

    func requestPacket(time: ntp_time_t) -> ntp_packet_t {
        var packet = ntp_packet_t()
        packet.version_number = 3
        packet.client_mode = 3
        packet.transmit_time = time
        return packet
    }
}

private let defaultNTPPort: Int = 123
