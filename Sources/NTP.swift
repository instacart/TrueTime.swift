//
//  NTP.swift
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
    let serverResponse: ntp_packet_t?
    let startTime: ntp_time_t?
    public init(time: NSDate, uptime: timeval) {
        self.init(time: time, uptime: uptime, serverResponse: nil, startTime: nil)
    }

    init(time: NSDate, uptime: timeval, serverResponse: ntp_packet_t?, startTime: ntp_time_t?) {
        self.time = time
        self.uptime = uptime
        self.serverResponse = serverResponse
        self.startTime = startTime
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

@objc public final class SNTPClient: NSObject {
    public static let sharedInstance = SNTPClient()
    public let timeout: NSTimeInterval
    public let maxRetries: Int
    public let maxConnections: Int
    required public init(timeout: NSTimeInterval = defaultTimeout,
                         maxRetries: Int = defaultMaxRetries,
                         maxConnections: Int = defaultMaxConnections) {
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.maxConnections = maxConnections
    }

    @nonobjc public func start(hostURLs hostURLs: [NSURL]) {
        precondition(!hostURLs.isEmpty, "Must include at least one host URL")
        dispatch_async(queue) { self.hostURLs = hostURLs }
        reachability.callbackQueue = queue
        reachability.callback = { [weak self] status in
            guard let strongSelf = self else { return }
            switch status {
                case .NotReachable:
                    strongSelf.debugLog("Network unreachable")
                    strongSelf.invokeCallbacks(.Failure(NSError(trueTimeError: .Offline)))
                    strongSelf.stopQueue()
                case .ReachableViaWWAN, .ReachableViaWiFi:
                    strongSelf.debugLog("Network reachable")
                    strongSelf.startQueue(hostURLs: strongSelf.hostURLs)
            }
        }

        reachability.startMonitoring()
    }

    public func pause() {
        reachability.stopMonitoring()
        dispatch_async(queue, stopQueue)
    }

    public func retrieveReferenceTime(
        queue callbackQueue: dispatch_queue_t = dispatch_get_main_queue(),
        callback: ReferenceTimeCallback
    ) {
        precondition(self.reachability.callback != nil, "Must start client before retrieving time")
        dispatch_async(queue) {
            guard let referenceTime = self.referenceTime else {
                if !self.reachability.online {
                    dispatch_async(callbackQueue) {
                        callback(.Failure(NSError(trueTimeError: .Offline)))
                    }
                } else {
                    self.callbacks.append((callbackQueue, callback))
                    if self.atEnd { // Retry if we failed last time.
                        self.startQueue(hostURLs: self.hostURLs)
                    }
                }
                return
            }

            dispatch_async(callbackQueue) {
                callback(.Success(referenceTime))
            }
        }
    }

#if DEBUG_LOGGING
    public var logCallback: (String -> Void)? = { message in print(message) }
    private func debugLog(@autoclosure message: () -> String) {
        logCallback?(message())
    }
#else
    private func debugLog(@autoclosure message: () -> String) {}
#endif

    private func debugLogProxy(message: String) { debugLog(message) }
    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-client", nil)
    private let reachability = Reachability()
    private var callbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var connections: [SNTPConnection] = []
    private var connectionResults: [ReferenceTimeResult] = []
    private var hostURLs: [NSURL] = []
    private var hosts: [SNTPHost] = []
    private var referenceTime: ReferenceTime?
    private var startTime: NSTimeInterval?
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

extension SNTPClient {
    // Avoid leak when bridging to Objective-C.
    // https://openradar.appspot.com/radar?id=6675608629149696
    @objc public func start(hostURLs hostURLs: NSArray) {
        let hostURLs = hostURLs.map { $0 as? NSURL}.filter { $0 != nil }.flatMap { $0 } ?? []
        start(hostURLs: hostURLs)
    }

    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?) {
        retrieveReferenceTime(success: success,
                              failure: failure,
                              onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?,
                                            onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue) { result in
            switch result {
                case let .Success(time):
                    success(NTPReferenceTime(time))
                case let .Failure(error):
                    failure?(error)
            }
        }
    }
}

// MARK: -

private extension SNTPClient {
    var unresolvedHosts: [SNTPHost] {
        return hosts.filter { !$0.isResolved && $0.canRetry }
    }

    var atEnd: Bool {
        let unresolvedHostCount = unresolvedHosts.count
        let unresolvedConnectionCount = connections.count - connectionResults.count
        debugLog("Unresolved hosts: \(unresolvedHostCount) \(unresolvedHosts), " +
                 "unresolved connections: \(unresolvedConnectionCount), " +
                 "total connections: \(connections.count), " +
                 "total hosts: \(hosts.count)")
        return unresolvedHostCount == 0 && unresolvedConnectionCount == 0
    }

    func startQueue(hostURLs hostURLs: [NSURL]) {
        let currentHostURLs = hosts.map { $0.hostURL }
        let started = referenceTime != nil
        guard currentHostURLs != hostURLs && !started else {
            debugLog("Already \(started ? "started" : "finished")")
            return
        }

        stopQueue()
        debugLog("Starting queue with hosts: \(hostURLs)")
        startTime = CFAbsoluteTimeGetCurrent()
        hosts = hostURLs.map { url in  SNTPHost(hostURL: url,
                                                timeout: timeout,
                                                maxRetries: maxRetries,
                                                onComplete: hostCallback,
                                                callbackQueue: queue) }
        throttleHosts()
        hosts.forEach { $0.logCallback = debugLogProxy }
    }

    func stopQueue() {
        debugLog("Stopping queue")
        hosts.forEach { $0.stop(waitUntilFinished: true) }
        connections.forEach { $0.close(waitUntilFinished: true) }
        connections = []
        hosts = []
        connectionResults = []
        startTime = nil
    }

    func throttleHosts() {
        let eligibleHosts = unresolvedHosts
        let activeHosts = Array(eligibleHosts[0..<min(maxConnections, eligibleHosts.count)])
        activeHosts.forEach { $0.resolve() }
    }

    func throttleConnections() {
        let eligibleConnections = connections.filter { $0.canRetry }
        let activeConnections = Array(eligibleConnections[0..<min(maxConnections,
                                                                  eligibleConnections.count)])
        activeConnections.forEach { $0.start(self.queue, onComplete: self.connectionCallback) }
        debugLog("Starting connections: \(activeConnections) (total: \(connections.count))")
    }

    func hostCallback(result: SNTPHostResult) {
        switch result {
            case let .Success(connections):
                connections.forEach { $0.logCallback = debugLogProxy }
                self.connections += connections
                throttleConnections()
                throttleHosts()
            case let .Failure(error):
                let unresolvedHostURLs = self.unresolvedHosts.map { $0.hostURL }
                debugLog("Got error resolving host, trying next one: \(error). " +
                         "Remaining: \(unresolvedHostURLs).")
                throttleHosts()
                if atEnd {
                    finish(.Failure(error))
                }
        }
    }

    func connectionCallback(result: ReferenceTimeResult) {
        debugLog("Appending result: \(result)")
        connectionResults.append(result)
        switch result {
            case let .Success(referenceTime):
                self.referenceTime = referenceTime
                finish(result)
            case .Failure:
                throttleConnections()
                if atEnd {
                    finish(result)
                }
        }
    }

    func finish(result: ReferenceTimeResult) {
        guard !hosts.isEmpty else {
            return // Guard against race condition where we receive two responses at once.
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        debugLog("\(connectionResults.count) results: \(connectionResults)")
        debugLog("Took \(endTime - startTime!)s")
        invokeCallbacks(result)
        stopQueue()
    }

    func invokeCallbacks(result: ReferenceTimeResult) {
        callbacks.forEach { (queue, callback) in
            dispatch_async(queue) {
                callback(result)
            }
        }
        callbacks = []
    }
}

private let defaultMaxConnections: Int = 3
private let defaultMaxRetries: Int = 5
private let defaultTimeout: NSTimeInterval = 30
