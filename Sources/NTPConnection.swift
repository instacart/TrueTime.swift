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
        var throttleConnections: (() -> Void)?
        let onComplete: NTPConnectionCallback = { connection, result in
            progress(connection, result)
            throttleConnections?()
        }
        let connections: [NTPConnection] = addresses.flatMap { address in
            (0..<config.numberOfSamples).map { _ in
                NTPConnection(address: address,
                              timeout: config.timeout,
                              maxRetries: config.maxRetries,
                              logger: logger,
                              callbackQueue: callbackQueue,
                              onComplete: onComplete)
            }
        }

        throttleConnections = {
            let remainingConnections = connections.filter { $0.canRetry }
            let activeConnections = Array(remainingConnections[0..<min(config.maxConnections,
                                                                       remainingConnections.count)])
            activeConnections.forEach { $0.start() }
        }
        throttleConnections?()
        return connections
    }

    required init(address: SocketAddress,
                  timeout: TimeInterval,
                  maxRetries: Int,
                  logger: LogCallback?,
                  callbackQueue: DispatchQueue,
                  onComplete: @escaping NTPConnectionCallback) {
        self.address = address
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.callbackQueue = callbackQueue
        self.onComplete = onComplete
        self.logger = logger
    }

    var canRetry: Bool {
        return self.attempts < self.maxRetries && !self.didTimeout && !self.isFinished
    }

    func start() {
        guard self.socket == nil else { return }
        let callback: CFSocketCallBack = { socket, callbackType, address, data, info in
            guard let info = info else { return }
            let retainedClient = Unmanaged<NTPConnection>.fromOpaque(info)
            let client = retainedClient.takeUnretainedValue()
            guard let socket = socket, CFSocketIsValid(socket) else { return }

            // Can't use switch here as these aren't defined as an enum.
            if callbackType == .dataCallBack {
                let data = unsafeBitCast(data, to: CFData.self) as Data
                client.complete(client.parseResponse(data))
            } else if callbackType == .writeCallBack {
                client.debugLog("Buffer \(client.address) writable - requesting time")
                do {
                    try client.requestTime()
                    client.startTimer() // Restart timer.
                } catch {
                    client.complete(.failure(error as NSError))
                }
            } else {
                assertionFailure("Unexpected socket callback")
            }
        }

        var context = CFSocketContext(version: 0,
                                      info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                                      retain: nil,
                                      release: nil,
                                      copyDescription: nil)
        let socket = CFSocketCreate(nil,
                                    address.family,
                                    SOCK_DGRAM,
                                    IPPROTO_UDP,
                                    NTPConnection.callbackFlags,
                                    callback,
                                    &context)!
        let runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        CFSocketConnectToAddress(socket, address.networkData as CFData, timeout)
        isFinished = false
        startTimer()
        self.socket = socket
        self.runLoopSource = runLoopSource
        self.attempts += 1
    }

    func stop() {
        timer?.cancel()
        timer = nil
        guard let socket = socket, let runLoopSource = runLoopSource else { return }
        let disabledFlags = NTPConnection.callbackFlags |
          kCFSocketAutomaticallyReenableDataCallBack |
          kCFSocketAutomaticallyReenableReadCallBack |
          kCFSocketAutomaticallyReenableWriteCallBack |
          kCFSocketAutomaticallyReenableAcceptCallBack
        CFSocketDisableCallBacks(socket, disabledFlags)
        CFSocketInvalidate(socket)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        self.socket = nil
        self.runLoopSource = nil
        Unmanaged.passUnretained(self).release()
    }

    func startTimer() {
        timer?.cancel()
        timer = .scheduled(timeInterval: timeout) { [weak self] _ in
            self?.complete(.failure(.init(trueTimeError: .timedOut)))
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    private var timer: DispatchBlockTimer?
    private static let callbackTypes: [CFSocketCallBackType] = [.dataCallBack, .writeCallBack]
    private static let callbackFlags: CFOptionFlags = callbackTypes.map {
        $0.rawValue
    }.reduce(0, |)
    private var attempts: Int = 0
    private var callbackQueue: DispatchQueue
    private var didTimeout: Bool = false
    private var isFinished: Bool = false
    private var onComplete: NTPConnectionCallback
    private var requestTicks: timeval?
    private var runLoopSource: CFRunLoopSource?
    private var socket: CFSocket?
    private var startTime: ntp_time_t?
}

private extension NTPConnection {
    func complete(_ result: FrozenNetworkTimeResult) {
        switch result {
        case let .failure(error) where attempts < maxRetries && !didTimeout:
            debugLog("Got error from \(address) (attempt \(attempts)), trying again. \(error)")
            stop()
            start()
        case .failure, .success:
            isFinished = true
            callbackQueue.async {
                self.onComplete(self, result)
            }
            stop()
        }
    }

    func requestTime() throws {
        guard let socket = self.socket else {
            self.debugLog("Socket closed prematurely")
            return
        }

        let startTime: ntp_time_t = .init(timeSince1970: .now())
        let requestTicks: timeval = .uptime()
        let packet = NTPConnection.requestPacket(startTime).bigEndian
        let interval = TimeInterval(milliseconds: startTime.milliseconds)
        self.startTime = startTime
        self.requestTicks = requestTicks
        debugLog("Sending time: \(Date(timeIntervalSince1970: interval))")
        let result = CFSocketSendData(socket, nil, packet.data as CFData, timeout)
        if result != .success {
            throw NSError(errno: errno)
        }
    }

    func parseResponse(_ responseData: Data) -> FrozenNetworkTimeResult {
        let responseTicks = timeval.uptime()
        guard responseData.count == MemoryLayout<ntp_packet_t>.size else {
            return .failure(NSError(trueTimeError: .badServerResponse)) // Invalid packet length.
        }
        guard let startTime = startTime, let requestTicks = requestTicks else {
            fatalError("Uninitialized timestamps")
        }

        let packet = responseData.withUnsafeBytes { $0.pointee as ntp_packet_t }.nativeEndian
        let responseTime = startTime.milliseconds + (responseTicks.milliseconds - requestTicks.milliseconds)
        guard let response = NTPResponse(packet: packet, responseTime: responseTime) else {
            return .failure(NSError(trueTimeError: .badServerResponse))
        }

        debugLog("Buffer \(self.address) has read data!")
        debugLog("Start time: \(startTime.milliseconds) ms, response: \(packet.timeDescription)")
        debugLog("Clock offset: \(response.offset) milliseconds")
        debugLog("Round-trip delay: \(response.delay) milliseconds")
        return .success(FrozenNetworkTime(time: response.networkDate,
                                          uptime: responseTicks,
                                          serverResponse: response,
                                          startTime: startTime))
    }

    static func requestPacket(_ time: ntp_time_t) -> ntp_packet_t {
        var packet = ntp_packet_t()
        packet.client_mode = 3
        packet.version_number = 3
        packet.transmit_time = time
        return packet
    }
}
