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
}

public struct ReferenceTime {
    public let time: NSDate
    public let uptime: timeval
    let serverResponse: NTPResponse?
    let startTime: ntp_time_t?
    let sampleSize: Int?
    let pool: NSURL?

    public init(time: NSDate, uptime: timeval) {
        self.init(time: time, uptime: uptime, serverResponse: nil, startTime: nil)
    }

    init(time: NSDate,
         uptime: timeval,
         serverResponse: NTPResponse?,
         startTime: ntp_time_t?,
         sampleSize: Int? = 0,
         pool: NSURL? = nil) {
        self.time = time
        self.uptime = uptime
        self.serverResponse = serverResponse
        self.startTime = startTime
        self.sampleSize = sampleSize
        self.pool = pool
    }

    init(referenceTime time: ReferenceTime, sampleSize: Int, pool: NSURL) {
        self.init(time: time.time,
                  uptime: time.uptime,
                  serverResponse: time.serverResponse,
                  startTime: time.startTime,
                  sampleSize: sampleSize,
                  pool: pool)
    }
}

public extension ReferenceTime {
    func now() -> NSDate {
        let currentUptime = timeval.uptime()
        let interval = NSTimeInterval(milliseconds: currentUptime.milliseconds -
                                                    uptime.milliseconds)
        return time.dateByAddingTimeInterval(interval)
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
        ntp.fetch(queue: callbackQueue, first: first, completion: completion)
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

// MARK: - Objective-C Bridging

@objc public final class NTPReferenceTime: NSObject {
    public init(_ referenceTime: ReferenceTime) {
        self.underlyingValue = referenceTime
    }

    public let underlyingValue: ReferenceTime
    public var time: NSDate { return underlyingValue.time }
    public var uptime: timeval { return underlyingValue.uptime }
    public func now() -> NSDate { return underlyingValue.now() }
}

extension TrueTimeClient {
    // Avoid leak when bridging to Objective-C.
    // https://openradar.appspot.com/radar?id=6675608629149696
    @objc public func start(hostURLs hostURLs: NSArray) {
        let hostURLs = hostURLs.map { $0 as? NSURL}.filter { $0 != nil }.flatMap { $0 } ?? []
        start(hostURLs: hostURLs)
    }

    @objc public func retrieveFirstReferenceTime(success success: NTPReferenceTime -> Void,
                                                 failure: (NSError -> Void)?) {
        retrieveFirstReferenceTime(success: success,
                                   failure: failure,
                                   onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?) {
        retrieveReferenceTime(success: success,
                              failure: failure,
                              onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveFirstReferenceTime(success success: NTPReferenceTime -> Void,
                                                 failure: (NSError -> Void)?,
                                                 onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue, first: { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        })
    }

    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?,
                                            onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue) { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        }
    }

    @objc(referenceTime) public var bridgedReferenceTime: NTPReferenceTime? {
        return self.referenceTime.map(NTPReferenceTime.init)
    }

    private func mapBridgedResult(result: ReferenceTimeResult,
                                  success: NTPReferenceTime -> Void,
                                  failure: (NSError -> Void)?) {
        result.map(NTPReferenceTime.init).analysis(ifSuccess: success,
                                                   ifFailure: { err in failure?(err) })
    }
}

let defaultLogger: LogCallback = { print($0) }
private let defaultMaxConnections: Int = 5
private let defaultMaxRetries: Int = 3
private let defaultMaxServers: Int = 5
private let defaultNumberOfSamples: Int = 4
private let defaultTimeout: NSTimeInterval = 8
