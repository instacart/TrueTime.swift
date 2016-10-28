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
    case CannotFindHost
    case DNSLookupFailed
    case TimedOut
    case Offline
    case BadServerResponse
    case NoValidPacket
}

@objc(NTPReferenceTime)
public final class ReferenceTime: NSObject, ReferenceTimeContainer {
    public var time: NSDate { return underlyingValue.time }
    public var uptime: timeval { return underlyingValue.uptime }
    public func now() -> NSDate { return underlyingValue.now() }

    public convenience init(time: NSDate, uptime: timeval) {
        self.init(FrozenReferenceTime(time: time, uptime: uptime))
    }

    init(_ underlyingValue: FrozenReferenceTime) {
        self.underlyingValueLock = GCDLock(value: underlyingValue)
    }

    public override var description: String {
        return "\(self.dynamicType)(underlyingValue: \(underlyingValue)"
    }

    public override var debugDescription: String {
        return "\(self.dynamicType)(underlyingValue: \(underlyingValue.debugDescription)"
    }

    private let underlyingValueLock: GCDLock<FrozenReferenceTime>
    var underlyingValue: FrozenReferenceTime {
        get { return underlyingValueLock.read() }
        set { underlyingValueLock.write(newValue) }
    }
}

public typealias ReferenceTimeResult = Result<ReferenceTime, NSError>
public typealias ReferenceTimeCallback = ReferenceTimeResult -> Void
public typealias LogCallback = String -> Void

@objc public final class TrueTimeClient: NSObject {
    public static let sharedInstance = TrueTimeClient()
    required public init(timeout: NSTimeInterval = defaultTimeout,
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

    @nonobjc public func start(hostURLs pools: [NSURL] = [NSURL(string: "time.apple.com")!]) {
        ntp.start(pools: pools)
    }

    public func pause() {
        ntp.pause()
    }

    public func retrieveReferenceTime(
        queue callbackQueue: dispatch_queue_t = dispatch_get_main_queue(),
        first: ReferenceTimeCallback? = nil,
        completion: ReferenceTimeCallback? = nil
    ) {
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
    public var timeout: NSTimeInterval { return config.timeout }
    public var maxRetries: Int { return config.maxRetries }
    public var maxConnections: Int { return config.maxConnections }
    public var maxServers: Int { return config.maxServers}
    public var numberOfSamples: Int { return config.numberOfSamples}

    private let config: NTPConfig
    private lazy var ntp: NTPClient = NTPClient(config: self.config)
}

extension TrueTimeClient {
    // Avoid leak when bridging to Objective-C.
    // https://openradar.appspot.com/radar?id=6675608629149696
    @objc public func start(hostURLs hostURLs: NSArray) {
        let hostURLs = hostURLs.map { $0 as? NSURL}.filter { $0 != nil }.flatMap { $0 } ?? []
        start(hostURLs: hostURLs)
    }

    @objc public func retrieveFirstReferenceTime(success success: ReferenceTime -> Void,
                                                 failure: (NSError -> Void)?) {
        retrieveFirstReferenceTime(success: success,
                                   failure: failure,
                                   onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveReferenceTime(success success: ReferenceTime -> Void,
                                            failure: (NSError -> Void)?) {
        retrieveReferenceTime(success: success,
                              failure: failure,
                              onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveFirstReferenceTime(success success: ReferenceTime -> Void,
                                                 failure: (NSError -> Void)?,
                                                 onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue, first: { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        })
    }

    @objc public func retrieveReferenceTime(success success: ReferenceTime -> Void,
                                            failure: (NSError -> Void)?,
                                            onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue) { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        }
    }

    private func mapBridgedResult(result: ReferenceTimeResult,
                                  success: ReferenceTime -> Void,
                                  failure: (NSError -> Void)?) {
        result.analysis(ifSuccess: success, ifFailure: { err in failure?(err) })
    }
}

let defaultLogger: LogCallback = { print($0) }
private let defaultMaxConnections: Int = 5
private let defaultMaxRetries: Int = 3
private let defaultMaxServers: Int = 5
private let defaultNumberOfSamples: Int = 4
private let defaultTimeout: NSTimeInterval = 8
