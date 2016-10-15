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

typealias NTPConnectionCallback = (NTPConnection, ReferenceTimeResult) -> Void

final class NTPConnection {
    let address: SocketAddress
    let timeout: NSTimeInterval
    let maxRetries: Int

    static func query(addresses addresses: [SocketAddress],
                      config: NTPConfig,
                      callbackQueue: dispatch_queue_t,
                      progress: NTPConnectionCallback) -> [NTPConnection] {
        let connections = addresses.flatMap { address in
            (0..<config.numberOfSamples).map { _ in
                NTPConnection(address: address,
                              timeout: config.timeout,
                              maxRetries: config.maxRetries)
            }
        }

        var throttleConnections: (() -> Void)? = nil
        let onComplete: NTPConnectionCallback = { connection, result in
            progress(connection, result)
            throttleConnections?()
        }

        throttleConnections = {
            let remainingConnections = connections.filter { $0.canRetry }
            let activeConnections = Array(remainingConnections[0..<min(config.maxConnections,
                                                                       remainingConnections.count)])
            activeConnections.forEach { $0.start(callbackQueue, onComplete: onComplete) }
        }
        throttleConnections?()
        return connections
    }

    required init(address: SocketAddress, timeout: NSTimeInterval, maxRetries: Int) {
        self.address = address
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    deinit {
        assert(!self.started, "Unclosed connection")
    }

    var canRetry: Bool {
        var canRetry: Bool = false
        dispatch_sync(lockQueue) {
            canRetry = self.attempts < self.maxRetries && !self.didTimeout && !self.finished
        }
        return canRetry
    }

    func start(callbackQueue: dispatch_queue_t, onComplete: NTPConnectionCallback) {
        dispatch_async(lockQueue) {
            guard !self.started else { return }

            var ctx = CFSocketContext(
                version: 0,
                info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: defaultCopyDescription
            )

            self.attempts += 1
            self.callbackQueue = callbackQueue
            self.onComplete = onComplete
            self.socket = CFSocketCreate(nil,
                                         self.address.family,
                                         SOCK_DGRAM,
                                         IPPROTO_UDP,
                                         self.dynamicType.callbackFlags,
                                         self.dataCallback,
                                         &ctx)

            if let socket = self.socket {
                CFSocketSetSocketFlags(socket, kCFSocketCloseOnInvalidate)
                self.source = CFSocketCreateRunLoopSource(nil, socket, 0)
            }

            if let source = self.source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes)
                self.startTimer()
            }
        }
    }

    func close(waitUntilFinished wait: Bool = false) {
        let fn = wait ? dispatch_sync : dispatch_async
        fn(lockQueue) {
            self.cancelTimer()
            guard let socket = self.socket, source = self.source else { return }
            let disabledFlags = self.dynamicType.callbackFlags |
                                kCFSocketAutomaticallyReenableDataCallBack |
                                kCFSocketAutomaticallyReenableReadCallBack |
                                kCFSocketAutomaticallyReenableWriteCallBack |
                                kCFSocketAutomaticallyReenableAcceptCallBack
            CFSocketDisableCallBacks(socket, disabledFlags)
            CFSocketInvalidate(socket)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes)
            self.socket = nil
            self.source = nil
            self.debugLog("Connection closed \(self.address)")
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
    private let dataCallback: CFSocketCallBack = { socket, type, address, data, info in
        let client = Unmanaged<NTPConnection>.fromOpaque(COpaquePointer(info))
                                             .takeUnretainedValue()
        guard let socket = socket where CFSocketIsValid(socket) else { return }

        // Can't use switch here as these aren't defined as an enum.
        if type == .DataCallBack {
            let data = Unmanaged<CFData>.fromOpaque(COpaquePointer(data)).takeUnretainedValue()
            client.handleResponse(data)
        } else if type == .WriteCallBack {
            client.debugLog("Buffer \(client.address) writable - requesting time")
            client.requestTime()
        } else {
            assertionFailure("Unexpected socket callback")
        }
    }

    var timer: dispatch_source_t?
    private static let callbackTypes: [CFSocketCallBackType] = [.DataCallBack, .WriteCallBack]
    private static let callbackFlags: CFOptionFlags = callbackTypes.map {
        $0.rawValue
    }.reduce(0, combine: |)
    private let lockQueue: dispatch_queue_t = dispatch_queue_create("com.instacart.ntp.connection",
                                                                    nil)
    private var attempts: Int = 0
    private var callbackQueue: dispatch_queue_t?
    private var didTimeout: Bool = false
    private var onComplete: NTPConnectionCallback?
    private var requestTicks: timeval?
    private var socket: CFSocket?
    private var source: CFRunLoopSource?
    private var startTime: ntp_time_t?
    private var finished: Bool = false
}

extension NTPConnection: TimedOperation {
    var timerQueue: dispatch_queue_t { return lockQueue }
    var started: Bool { return self.socket != nil }

    func timeoutError(error: NSError) {
        self.didTimeout = true
        complete(.Failure(error))
    }
}

private extension NTPConnection {
    func complete(result: ReferenceTimeResult) {
        guard let callbackQueue = callbackQueue, onComplete = onComplete else {
            assertionFailure("Completion callback not initialized")
            return
        }

        close()
        switch result {
            case let .Failure(error) where attempts < maxRetries && !didTimeout:
                debugLog("Got error from \(address) (attempt \(attempts)), " +
                         "trying again. \(error)")
                start(callbackQueue, onComplete: onComplete)
            case .Failure, .Success:
                finished = true
                dispatch_async(callbackQueue) {
                    onComplete(self, result)
                }
        }
    }

    func requestTime() {
        dispatch_async(lockQueue) {
            guard let socket = self.socket else {
                self.debugLog("Socket closed")
                return
            }

            self.startTime = ntp_time_t(timeSince1970: .now())
            self.requestTicks = .uptime()
            if let startTime = self.startTime {
                let packet = self.requestPacket(startTime).bigEndian
                let interval = NSTimeInterval(milliseconds: startTime.milliseconds)
                self.debugLog("Sending time: \(NSDate(timeIntervalSince1970: interval))")
                let err = CFSocketSendData(socket,
                                           self.address.networkData,
                                           packet.data,
                                           self.timeout)
                if err != .Success {
                    self.complete(.Failure(NSError(errno: errno)))
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
            let responseTime = startTime.milliseconds + (responseTicks.milliseconds -
                                                         requestTicks.milliseconds)

            guard let response = NTPResponse(packet: packet, responseTime: responseTime) else {
                self.complete(.Failure(NSError(trueTimeError: .BadServerResponse)))
                return
            }

            self.debugLog("Buffer \(self.address) has read data!")
            self.debugLog("Start time: \(startTime.milliseconds) ms, " +
                          "response: \(packet.timeDescription)")
            self.debugLog("Clock offset: \(response.offset) milliseconds")
            self.debugLog("Round-trip delay: \(response.delay) milliseconds")
            self.complete(.Success(ReferenceTime(time: response.networkDate,
                                                 uptime: responseTicks,
                                                 serverResponse: response,
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

struct NTPResponse {
    let packet: ntp_packet_t
    let responseTime: Int64
    let receiveTime: timeval
    init?(packet: ntp_packet_t, responseTime: Int64, receiveTime: timeval = .now()) {
        self.packet = packet
        self.responseTime = responseTime
        self.receiveTime = receiveTime
        if !isValidResponse {
            return nil
        }
    }

    // See https://en.wikipedia.org/wiki/Network_Time_Protocol#Clock_synchronization_algorithm
    var offset: Int64 {
        let T = offsetValues
        return ((T[1] - T[0]) + (T[2] - T[3])) / 2
    }

    var delay: Int64 {
        let T = offsetValues
        return (T[3] - T[0]) - (T[2] - T[1])
    }

    var networkDate: NSDate {
        let interval = NSTimeInterval(milliseconds: responseTime + offset)
        return NSDate(timeIntervalSince1970: interval)
    }

    private let maxRootDispersion: Int64 = 100
    private let maxDelayDelta: Int64 = 100
    private let ntpModeServer: UInt8 = 4
    private let leapIndicatorUnknown: UInt8 = 3
}

private extension NTPResponse {
    var isValidResponse: Bool {
        return !packet.isZero &&
                packet.root_delay.durationInMilliseconds < maxRootDispersion &&
                packet.root_dispersion.durationInMilliseconds < maxRootDispersion &&
                packet.client_mode == ntpModeServer &&
                packet.stratum > 0 && packet.stratum < 16 &&
                packet.leap_indicator != leapIndicatorUnknown &&
                abs(receiveTime.milliseconds -
                    packet.originate_time.milliseconds -
                    delay) < maxDelayDelta
    }

    var offsetValues: [Int64] {
        return [packet.originate_time.milliseconds,
                packet.receive_time.milliseconds,
                packet.transmit_time.milliseconds,
                responseTime]
    }
}
