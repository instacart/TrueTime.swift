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

typealias NTPConnectionCallback = (NTPConnection, FrozenNetworkTimeResult) -> Void

final class NTPConnection {
    let address: SocketAddress
    let timeout: TimeInterval
    let maxRetries: Int
    var logger: LogCallback?

    static func query(addresses: [SocketAddress],
                      config: NTPConfig,
                      logger: LogCallback?,
                      callbackQueue: DispatchQueue,
                      progress: @escaping NTPConnectionCallback) -> [NTPConnection] {
        let connections = addresses.flatMap { address in
            (0..<config.numberOfSamples).map { _ in
                NTPConnection(address: address,
                              timeout: config.timeout,
                              maxRetries: config.maxRetries,
                              logger: logger)
            }
        }

        var throttleConnections: (() -> Void)?
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

    required init(address: SocketAddress,
                  timeout: TimeInterval,
                  maxRetries: Int,
                  logger: LogCallback?) {
        self.address = address
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.logger = logger
    }

    deinit {
        assert(!self.started, "Unclosed connection")
    }

    var canRetry: Bool {
        var canRetry: Bool = false
        lockQueue.sync {
            canRetry = self.attempts < self.maxRetries && !self.didTimeout && !self.finished
        }
        return canRetry
    }

    func start(_ callbackQueue: DispatchQueue, onComplete: @escaping NTPConnectionCallback) {
        lockQueue.async {
            guard !self.started else { return }

            var ctx = CFSocketContext(
                version: 0,
                info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            self.attempts += 1
            self.callbackQueue = callbackQueue
            self.onComplete = onComplete
            self.socket = CFSocketCreate(nil,
                                         self.address.family,
                                         SOCK_DGRAM,
                                         IPPROTO_UDP,
                                         NTPConnection.callbackFlags,
                                         self.dataCallback,
                                         &ctx)

            if let socket = self.socket {
                CFSocketSetSocketFlags(socket, kCFSocketCloseOnInvalidate)
                self.source = CFSocketCreateRunLoopSource(nil, socket, 0)
            }

            if let source = self.source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
                self.startTimer()
            }
        }
    }

    func close(waitUntilFinished wait: Bool = false) {
        let work = {
            self.cancelTimer()
            guard let socket = self.socket, let source = self.source else { return }
            let disabledFlags = NTPConnection.callbackFlags |
                                kCFSocketAutomaticallyReenableDataCallBack |
                                kCFSocketAutomaticallyReenableReadCallBack |
                                kCFSocketAutomaticallyReenableWriteCallBack |
                                kCFSocketAutomaticallyReenableAcceptCallBack
            CFSocketDisableCallBacks(socket, disabledFlags)
            CFSocketInvalidate(socket)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            self.socket = nil
            self.source = nil
            self.debugLog("Connection closed \(self.address)")
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

    private let dataCallback: CFSocketCallBack = { socket, type, address, data, info in
        guard let info = info else { return }
        let retainedClient = Unmanaged<NTPConnection>.fromOpaque(info)
        let client = retainedClient.takeUnretainedValue()
        guard let socket = socket, CFSocketIsValid(socket) else { return }

        // Can't use switch here as these aren't defined as an enum.
        if type == .dataCallBack {
            let data = unsafeBitCast(data, to: CFData.self) as Data
            client.handleResponse(data)
            retainedClient.release()
        } else if type == .writeCallBack {
            client.debugLog("Buffer \(client.address) writable - requesting time")
            client.requestTime()
        } else {
            assertionFailure("Unexpected socket callback")
        }
    }

    var timer: DispatchSourceTimer?
    private static let callbackTypes: [CFSocketCallBackType] = [.dataCallBack, .writeCallBack]
    private static let callbackFlags: CFOptionFlags = callbackTypes.map {
        $0.rawValue
    }.reduce(0, |)
    fileprivate let lockQueue = DispatchQueue(label: "com.instacart.ntp.connection")
    fileprivate var attempts: Int = 0
    fileprivate var callbackQueue: DispatchQueue?
    fileprivate var didTimeout: Bool = false
    fileprivate var onComplete: NTPConnectionCallback?
    fileprivate var requestTicks: timeval?
    fileprivate var socket: CFSocket?
    fileprivate var source: CFRunLoopSource?
    fileprivate var startTime: ntp_time_t?
    fileprivate var finished: Bool = false
}

extension NTPConnection: TimedOperation {
    var timerQueue: DispatchQueue { return lockQueue }
    var started: Bool { return self.socket != nil }

    func timeoutError(_ error: NSError) {
        self.didTimeout = true
        complete(.failure(error))
    }
}

private extension NTPConnection {
    func complete(_ result: FrozenNetworkTimeResult) {
        guard let callbackQueue = callbackQueue, let onComplete = onComplete else {
            assertionFailure("Completion callback not initialized")
            return
        }

        close()
        switch result {
            case let .failure(error) where attempts < maxRetries && !didTimeout:
                debugLog("Got error from \(address) (attempt \(attempts)), " +
                         "trying again. \(error)")
                start(callbackQueue, onComplete: onComplete)
            case .failure, .success:
                finished = true
                callbackQueue.async {
                    onComplete(self, result)
                }
        }
    }

    func requestTime() {
        lockQueue.async {
            guard let socket = self.socket else {
                self.debugLog("Socket closed")
                return
            }

            self.startTime = ntp_time_t(timeSince1970: .now())
            self.requestTicks = .uptime()
            if let startTime = self.startTime {
                let packet = self.requestPacket(startTime).bigEndian
                let interval = TimeInterval(milliseconds: startTime.milliseconds)
                self.debugLog("Sending time: \(Date(timeIntervalSince1970: interval))")
                let err = CFSocketSendData(socket,
                                           self.address.networkData as CFData,
                                           packet.data as CFData,
                                           self.timeout)
                if err != .success {
                    self.complete(.failure(NSError(errno: errno)))
                } else {
                    self.startTimer()
                }
            }
        }
    }

    func handleResponse(_ data: Data) {
        let responseTicks = timeval.uptime()
        lockQueue.async {
            guard self.started else { return } // Socket closed.
            guard data.count == MemoryLayout<ntp_packet_t>.size else { return } // Invalid packet length.
            guard let startTime = self.startTime, let requestTicks = self.requestTicks else {
                assertionFailure("Uninitialized timestamps")
                return
            }

            let packet = data.withUnsafeBytes { $0.pointee as ntp_packet_t }.nativeEndian
            let responseTime = startTime.milliseconds + (responseTicks.milliseconds -
                                                         requestTicks.milliseconds)

            guard let response = NTPResponse(packet: packet, responseTime: responseTime) else {
                self.complete(.failure(NSError(trueTimeError: .badServerResponse)))
                return
            }

            self.debugLog("Buffer \(self.address) has read data!")
            self.debugLog("Start time: \(startTime.milliseconds) ms, " +
                          "response: \(packet.timeDescription)")
            self.debugLog("Clock offset: \(response.offset) milliseconds")
            self.debugLog("Round-trip delay: \(response.delay) milliseconds")
            self.complete(.success(FrozenNetworkTime(time: response.networkDate,
                                                     uptime: responseTicks,
                                                     serverResponse: response,
                                                     startTime: startTime)))
        }
    }

    func requestPacket(_ time: ntp_time_t) -> ntp_packet_t {
        var packet = ntp_packet_t()
        packet.client_mode = 3
        packet.version_number = 3
        packet.transmit_time = time
        return packet
    }
}
