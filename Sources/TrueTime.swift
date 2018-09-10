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
    /// Indicates given host could not be found.
    case cannotFindHost

    /// Indicates a failed connection due to a DNS lookup failure.
    case dnsLookupFailed

    /// Indicates the connection timed out.
    case timedOut

    /// Indicates the connection failed due to the device being offline.
    case offline

    /// Indicates the NTP lookup failed due to a bad server response.
    case badServerResponse

    /// Indicates that no valid packet could be found.
    case noValidPacket
}

/// An auto-updating network time sent from latest NTP server. Will
/// automatically be updated when network is online and past `pollInterval` has
/// passed. Safe to cache and use across threads.
@objc(NTPReferenceTime) public final class ReferenceTime: NSObject {
    /// Current uptime subtracted by uptime at the time of network request.
    @objc public var uptimeInterval: TimeInterval { return underlyingValue.uptimeInterval }

    /// Time sent from NTP server.
    @objc public var time: Date { return underlyingValue.time }

    /// Uptime at the time of network response.
    @objc public var uptime: timeval { return underlyingValue.uptime }

    /// Current time relative to adjusted network time.
    @objc public func now() -> Date { return underlyingValue.now() }

    /// Creates a new reference time with the given values.
    ///
    /// - parameter time: Time sent from NTP server.
    /// - parameter uptime: Uptime at the time of network response.
    public convenience init(time: Date, uptime: timeval) {
        self.init(FrozenReferenceTime(time: time, uptime: uptime))
    }

    init(_ underlyingValue: FrozenTime) {
        self.underlyingValueLock = GCDLock(value: underlyingValue)
    }

    public override var description: String { return "\(ReferenceTime.self)(underlyingValue: \(underlyingValue)" }
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

    /// Creates a new TrueTime client with the given configuration.
    ///
    /// - parameter timeout: Network timeout interval for each NTP connection
    ///                      (default 8).
    /// - parameter maxRetries: The maximum number of times to retry each
    ///                         request (default 3).
    /// - parameter maxConnections: The connections to be invoked at once
    ///                             (default 5).
    /// - parameter maxServers: The max number of servers to be queried (default 5).
    /// - parameter numberOfSamples: The total number of samples to collected
    ///                              for each reference time (default 4).
    /// - parameter pollInterval: Time interval until reference times are
    ///                           expired and polling restarts.
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

    /// Start NTP polling with the given pool. This only needs to be called once
    /// (for example at app launch). The library will automatically pause/restart
    /// depending on network conditions. There's no need to call this again
    /// unless the client has been manually paused.
    @objc public func start(pool: [String] = ["time.apple.com"], port: Int = 123) {
        ntp.start(pool: pool, port: port)
    }

    /// Pause NTP polling.
    @objc public func pause() {
        ntp.pause()
    }

    /// Returns the current reference time if cached, or waits until polling has
    /// finished. If the device is offline when waiting to fetch and no time is
    /// cached, this will error out immediately. Offline support may be added in
    /// a future release. Times are safe to cache and use across threads.
    ///
    /// - parameter queue: Queue to invoke callbacks on.
    /// - parameter first: Invoked upon retrieving the first reference time.
    /// - parameter completion: Invoked when `numberOfSamples` samples has been reached.
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
    @objc(start) public func bridgedStart() {
        start()
    }

    @objc public func fetchFirstIfNeeded(success: @escaping (ReferenceTime) -> Void, failure: ((NSError) -> Void)?) {
        fetchFirstIfNeeded(success: success, failure: failure, onQueue: .main)
    }

    @objc public func fetchIfNeeded(success: @escaping (ReferenceTime) -> Void, failure: ((NSError) -> Void)?) {
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
