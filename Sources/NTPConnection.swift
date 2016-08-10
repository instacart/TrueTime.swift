//
//  NTPConnection.swift
//  TrueTime
//
//  Created by Michael Sanders on 8/10/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Foundation
import Result

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

    var timer: dispatch_source_t?
    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-connection",
                                                                    nil)
    private var attempts: Int = 0
    private var callbackQueue: dispatch_queue_t?
    private var didTimeOut: Bool = false
    private var onComplete: ReferenceTimeCallback?
    private var requestTicks: timeval?
    private var socket: CFSocket?
    private var startTime: ntp_time_t?
}

extension SNTPConnection: SNTPNode {
    var timerQueue: dispatch_queue_t { return lockQueue }
    var started: Bool { return self.socket != nil }

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

            self.startTime = ntp_time_t(timeSince1970: timeval.now())
            self.requestTicks = timeval.uptime()
            if let startTime = self.startTime {
                let packet = self.requestPacket(startTime).bigEndian
                let interval = NSTimeInterval(milliseconds: startTime.milliseconds)
                debugLog("Sending time: \(NSDate(timeIntervalSince1970: interval))")
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
            let isValidResponse = !packet.isZero &&
                                   packet.originate_time.milliseconds == startTime.milliseconds &&
                                   packet.root_delay.durationInMilliseconds <= 100 &&
                                   packet.root_dispersion.durationInMilliseconds <= 100 &&
                                   packet.client_mode == ntpModeServer &&
                                   packet.stratum < 16
            guard isValidResponse else { // Guard against outliers.
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
        packet.client_mode = 3
        packet.version_number = 3
        packet.transmit_time = time
        return packet
    }
}

private let ntpModeServer: UInt8 = 4
