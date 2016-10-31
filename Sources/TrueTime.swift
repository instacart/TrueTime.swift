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
    public static let sharedInstance = TrueTimeClient()
    required public init(timeout: TimeInterval = defaultTimeout,
                         maxRetries: Int = defaultMaxRetries,
                         maxConnections: Int = defaultMaxConnections,
                         maxServers: Int = defaultMaxServers,
                         numberOfSamples: Int = defaultNumberOfSamples) {
        config = NTPConfig(timeout: timeout,
                           maxRetries: maxRetries,
                           maxConnections: maxConnections,
                           maxServers: maxServers,
                           numberOfSamples: numberOfSamples)
    }

    public func start(hostURLs pools: [URL] = [URL(string: "time.apple.com")!]) {
        ntp.start(pools: pools)
    }

    public func pause() {
        ntp.pause()
    }

    public func retrieveReferenceTime(queue callbackQueue: DispatchQueue = DispatchQueue.main,
                                      first: ReferenceTimeCallback? = nil,
                                      completion: ReferenceTimeCallback? = nil) {
        ntp.fetchIfNeeded(queue: callbackQueue, first: first, completion: completion)
    }

#if DEBUG_LOGGING
    public var logCallback: LogCallback? = defaultLogger {
        didSet {
            ntp.logger = logCallback
        }
    }
#endif

    public var referenceTime: ReferenceTime? { return ntp.referenceTime }
    public var timeout: TimeInterval { return config.timeout }
    public var maxRetries: Int { return config.maxRetries }
    public var maxConnections: Int { return config.maxConnections }
    public var maxServers: Int { return config.maxServers}
    public var numberOfSamples: Int { return config.numberOfSamples}

    private let config: NTPConfig
    private lazy var ntp: NTPClient = NTPClient(config: self.config)
}

extension TrueTimeClient {
    @objc public func retrieveFirstReferenceTime(success: @escaping (ReferenceTime) -> Void,
                                                 failure: ((NSError) -> Void)?) {
        retrieveFirstReferenceTime(success: success,
                                   failure: failure,
                                   onQueue: DispatchQueue.main)
    }

    @objc public func retrieveReferenceTime(success: @escaping (ReferenceTime) -> Void,
                                            failure: ((NSError) -> Void)?) {
        retrieveReferenceTime(success: success,
                              failure: failure,
                              onQueue: DispatchQueue.main)
    }

    @objc public func retrieveFirstReferenceTime(success: @escaping (ReferenceTime) -> Void,
                                                 failure: ((NSError) -> Void)?,
                                                 onQueue queue: DispatchQueue) {
        retrieveReferenceTime(queue: queue, first: { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        })
    }

    @objc public func retrieveReferenceTime(success: @escaping (ReferenceTime) -> Void,
                                            failure: ((NSError) -> Void)?,
                                            onQueue queue: DispatchQueue) {
        retrieveReferenceTime(queue: queue) { result in
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
private let defaultMaxConnections: Int = 5
private let defaultMaxRetries: Int = 3
private let defaultMaxServers: Int = 5
private let defaultNumberOfSamples: Int = 4
private let defaultTimeout: TimeInterval = 8
