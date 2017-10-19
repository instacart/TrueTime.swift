//
//  TrueTime.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Foundation
import Result

@objc public enum TrueTimeError: Int {
    case cannotFindHost
    case dnsLookupFailed
    case timedOut
    case offline
    case badServerResponse
    case noValidPacket
}

@objc(NTPReferenceTime)
public final class ReferenceTime: NSObject {
    public var uptimeInterval: TimeInterval { return underlyingValue.uptimeInterval }
    public var time: Date { return underlyingValue.time }
    public var uptime: timeval { return underlyingValue.uptime }
    public func now() -> Date { return underlyingValue.now() }

    public convenience init(time: Date, uptime: timeval) {
        self.init(FrozenReferenceTime(time: time, uptime: uptime))
    }

    init(_ underlyingValue: FrozenTime) {
        self.underlyingValueLock = GCDLock(value: underlyingValue)
    }

    public override var description: String {
        return "\(type(of: self))(underlyingValue: \(underlyingValue)"
    }

    private let underlyingValueLock: GCDLock<FrozenTime>
    var underlyingValue: FrozenTime {
        get { return underlyingValueLock.read() }
        set { underlyingValueLock.write(newValue) }
    }
}

public typealias ReferenceTimeResult = Result<ReferenceTime, NSError>
public typealias ReferenceTimeCallback = (ReferenceTimeResult) -> Void
public typealias LogCallback = (String) -> Void

@objc public final class TrueTimeClient: NSObject {
    @objc public static let sharedInstance = TrueTimeClient()
    @objc required public init(timeout: TimeInterval = 8,
                               maxRetries: Int = 3,
                               maxConnections: Int = 5,
                               maxServers: Int = 5,
                               numberOfSamples: Int = 4,
                               pollInterval: TimeInterval = 512) {
        config = NTPConfig(timeout: timeout,
                           maxRetries: maxRetries,
                           maxConnections: maxConnections,
                           maxServers: maxServers,
                           numberOfSamples: numberOfSamples,
                           pollInterval: pollInterval)
        ntp = NTPClient(config: config)
    }

    @objc public func start(hostURLs pools: [URL] = [URL(string: "time.apple.com")!]) {
        ntp.start(pools: pools)
    }

    @objc public func pause() {
        ntp.pause()
    }

    public func fetchIfNeeded(queue callbackQueue: DispatchQueue = .main,
                              first: ReferenceTimeCallback? = nil,
                              completion: ReferenceTimeCallback? = nil) {
        ntp.fetchIfNeeded(queue: callbackQueue, first: first, completion: completion)
    }

#if DEBUG_LOGGING
    @objc public var logCallback: LogCallback? = defaultLogger {
        didSet {
            ntp.logger = logCallback
        }
    }
#endif

    @objc public var referenceTime: ReferenceTime? { return ntp.referenceTime }
    @objc public var timeout: TimeInterval { return config.timeout }
    @objc public var maxRetries: Int { return config.maxRetries }
    @objc public var maxConnections: Int { return config.maxConnections }
    @objc public var maxServers: Int { return config.maxServers}
    @objc public var numberOfSamples: Int { return config.numberOfSamples}

    private let config: NTPConfig
    private let ntp: NTPClient
}

extension TrueTimeClient {
    @objc public func fetchFirstIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                         failure: ((NSError) -> Void)?) {
        fetchFirstIfNeeded(success: success, failure: failure, onQueue: .main)
    }

    @objc public func fetchIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                    failure: ((NSError) -> Void)?) {
        fetchIfNeeded(success: success, failure: failure, onQueue: .main)
    }

    @objc public func fetchFirstIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                         failure: ((NSError) -> Void)?,
                                         onQueue queue: DispatchQueue) {
        fetchIfNeeded(queue: queue, first: { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        })
    }

    @objc public func fetchIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                    failure: ((NSError) -> Void)?,
                                    onQueue queue: DispatchQueue) {
        fetchIfNeeded(queue: queue) { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        }
    }

    private func mapBridgedResult(_ result: ReferenceTimeResult,
                                  success: (ReferenceTime) -> Void,
                                  failure: ((NSError) -> Void)?) {
        result.analysis(ifSuccess: success, ifFailure: { err in failure?(err) })
    }
}

let defaultLogger: LogCallback = { print($0) }
