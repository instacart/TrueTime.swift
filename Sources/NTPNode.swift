//
//  NTPNode.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/18/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import CTrueTime

protocol SNTPNode {
    var timeout: NSTimeInterval { get }
    var onComplete: ReferenceTimeCallback { get }
    func start()
    func close()
}

final class SNTPHost {
    let hostURL: NSURL
    let timeout: NSTimeInterval
    let onComplete: ReferenceTimeCallback

    required init(hostURL: NSURL,
                  timeout: NSTimeInterval,
                  onComplete: ReferenceTimeCallback) {
        self.hostURL = hostURL
        self.timeout = timeout
        self.onComplete = onComplete
    }

    private var closed: Bool = false
    private var connections: [SNTPConnection] = []
    private static let hostCallback: CFHostClientCallBack = { (host, infoType, error, info)  in
        let client = Unmanaged<SNTPHost>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
        debugLog("Resolving hosts")
        client.connect(host)
    }
}

extension SNTPHost: SNTPNode {
    func start() {
        closed = false
        let host = CFHostCreateWithName(nil, hostURL.absoluteString).takeUnretainedValue()
        var ctx = CFHostClientContext(
            version: 0,
            info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: unsafeBitCast(0, CFAllocatorCopyDescriptionCallBack.self)
        )
        CFHostSetClient(host, self.dynamicType.hostCallback, &ctx)
        CFHostScheduleWithRunLoop(host, CFRunLoopGetMain(), kCFRunLoopDefaultMode)

        var err: CFStreamError = CFStreamError()
        if !CFHostStartInfoResolution(host, .Addresses, &err) {
            onComplete(.Failure(.UnresolvableHost(underlyingError: err)))
        }
    }

    func close() {
        closed = true
        connections.forEach { $0.close() }
        connections = []
    }
}

private extension SNTPHost {
    func connect(host: CFHost) {
        guard !closed else {
            debugLog("Closed")
            return
        }

        var resolved: DarwinBoolean = false
        let port = hostURL.port?.integerValue ?? 123
        let addressData = CFHostGetAddressing(host,
                                              &resolved)?.takeUnretainedValue() as [AnyObject]?
        guard let addresses = addressData as? [NSData] where resolved else {
            onComplete(.Failure(.UnresolvableHost(underlyingError: nil)))
            return
        }

        let sockAddresses = addresses.map { data -> sockaddr_in in
            var addr = (data.decode() as sockaddr_in).nativeEndian
            addr.sin_port = UInt16(port)
            return addr
        }.filter { addr in addr.sin_addr.s_addr != 0 }

        connections = sockAddresses.map { SNTPConnection(socketAddress: $0,
                                                         timeout: timeout,
                                                         onComplete: onComplete) }
        connections.forEach { $0.start() }
        debugLog("Resolved hosts: \(sockAddresses)")
    }
}

final class SNTPConnection {
    let socketAddress: sockaddr_in
    let timeout: NSTimeInterval
    let onComplete: ReferenceTimeCallback

    required init(socketAddress: sockaddr_in,
                  timeout: NSTimeInterval,
                  onComplete: ReferenceTimeCallback) {
        self.socketAddress = socketAddress
        self.timeout = timeout
        self.onComplete = onComplete
    }

    deinit {
        close()
    }

    private static let dataCallback: CFSocketCallBack = { (socket, type, address, data, info)  in
        let client = Unmanaged<SNTPConnection>.fromOpaque(COpaquePointer(info))
                                              .takeUnretainedValue()
        guard CFSocketIsValid(socket) else { return }

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

    private var socket: CFSocket?
    private var startTime: timeval?
    private var requestTicks: timeval?
}

extension SNTPConnection: SNTPNode {
    func start() {
        if socket != nil {
            assertionFailure("Already started")
            return
        }

        let callbackTypes: [CFSocketCallBackType] = [.DataCallBack, .WriteCallBack]
        var ctx = CFSocketContext(
            version: 0,
            info: UnsafeMutablePointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: unsafeBitCast(0, CFAllocatorCopyDescriptionCallBack.self)
        )

        socket = CFSocketCreate(nil,
                                PF_INET,
                                SOCK_DGRAM,
                                IPPROTO_UDP,
                                callbackTypes.map { $0.rawValue }.reduce(0, combine: |),
                                self.dynamicType.dataCallback,
                                &ctx)

        if let socket = socket {
            let source = CFSocketCreateRunLoopSource(nil, socket, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes)
        }
    }

    func close() {
        debugLog("Connection closed \(socketAddress)")
        if let socket = socket {
            CFSocketInvalidate(socket)
        }
    }
}

private extension SNTPConnection {
    func requestTime() {
        guard let socket = socket else {
            assertionFailure("Host not initialized")
            return
        }

        startTime = timeval.now()
        requestTicks = timeval.uptime()
        if let startTime = startTime {
            let time = ntp_time_t(startTime)
            let packet = requestPacket(time).bigEndian
            debugLog("Sending time: \(NSDate(timeIntervalSince1970: NSTimeInterval(time)))")
            let err = CFSocketSendData(socket, socketAddress.bigEndian.data, packet.data, timeout)
            if err != .Success {
                onComplete(.Failure(.ConnectionError(underlyingError: NSError(errno: errno))))
            }
        }
    }

    func handleResponse(data: NSData) {
        let responseTicks = timeval.uptime()
        guard let startTime = startTime, requestTicks = requestTicks else {
            assertionFailure("Uninitialized timestamps")
            return
        }

        let packet = (data.decode() as ntp_packet_t).nativeEndian
        guard !packet.isZero else { // Guard against dropped packets.
            onComplete(.Failure(.InvalidResponse))
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

        debugLog("Buffer \(socketAddress) has read data!")
        debugLog("Start time: \(startTime.milliseconds) ms, response: \(packet)")
        debugLog("Clock offset: \(offset) milliseconds")
        debugLog("Round-trip delay: \(delay) milliseconds")
        onComplete(.Success(ReferenceTime(time: trueTime,
                                          uptime: responseTicks,
                                          serverResponse: packet,
                                          startTime: startTime)))
    }

    func requestPacket(time: ntp_time_t) -> ntp_packet_t {
        var packet = ntp_packet_t()
        packet.version_number = 3
        packet.client_mode = 3
        packet.transmit_time = time
        return packet
    }
}
