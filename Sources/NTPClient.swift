//
//  NTPClient.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/12/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Result

struct NTPConfig {
    let timeout: NSTimeInterval
    let maxRetries: Int
    let maxConnections: Int
    let maxServers: Int
    let numberOfSamples: Int
}

final class NTPClient {
    let config: NTPConfig
    init(config: NTPConfig) {
        self.config = config
    }

    func start(pools poolURLs: [NSURL]) {
        precondition(!poolURLs.isEmpty, "Must include at least one pool URL")
        precondition(reachability.callback == nil, "Already started")
        dispatch_async(queue) { self.poolURLs = poolURLs }
        reachability.callbackQueue = queue
        reachability.callback = updateReachability
        reachability.startMonitoring()
    }

    func pause() {
        reachability.stopMonitoring()
        dispatch_async(queue, stopQueue)
    }

    func fetch(queue callbackQueue: dispatch_queue_t,
               first: ReferenceTimeCallback? = nil,
               completion: ReferenceTimeCallback? = nil) {
        precondition(reachability.callback != nil, "Must start client before retrieving time")
        dispatch_async(queue) {
            if let referenceTime = self.referenceTime {
                dispatch_async(callbackQueue) {
                    first?(.Success(referenceTime))
                }
            } else if let first = first {
                self.startCallbacks.append((callbackQueue, first))
            }

            if let referenceTime = self.referenceTime where self.finished {
                dispatch_async(callbackQueue) {
                    completion?(.Success(referenceTime))
                }
            } else {
                if let completion = completion {
                    self.completionCallbacks.append((callbackQueue, completion))
                }
                self.updateReachability(status: self.reachability.status ?? .NotReachable)
            }
        }
    }

    var referenceTime: ReferenceTime? {
        var referenceTime: ReferenceTime?
        dispatch_sync(referenceTimeLock) {
            referenceTime = self.currentReferenceTime
        }
        return referenceTime
    }

#if DEBUG_LOGGING
    var logCallback: (String -> Void)?
    private func debugLog(@autoclosure message: () -> String) {
        logCallback?(message())
    }
#else
    private func debugLog(@autoclosure message: () -> String) {}
#endif

    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.ntp.client", nil)
    private let reachability = Reachability()
    private let referenceTimeLock: dispatch_queue_t = dispatch_queue_create(nil, nil)
    private var completionCallbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var connections: [NTPConnection] = []
    private var currentReferenceTime: ReferenceTime?
    private var finished: Bool = false
    private var poolURLs: [NSURL] = [] {
        didSet {
            invalidate()
        }
    }
    private var startCallbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var startTime: NSTimeInterval?
}

private extension NTPClient {
    var started: Bool { return startTime != nil }
    func updateReachability(status status: ReachabilityStatus) {
        switch status {
            case .NotReachable:
                debugLog("Network unreachable")
                finish(.Failure(NSError(trueTimeError: .Offline)))
            case .ReachableViaWWAN, .ReachableViaWiFi:
                debugLog("Network reachable")
                startQueue(poolURLs: poolURLs)
        }
    }

    func startQueue(poolURLs poolURLs: [NSURL]) {
        guard !started && !finished else {
            debugLog("Already \(started ? "started" : "finished")")
            return
        }

        startTime = CFAbsoluteTimeGetCurrent()
        debugLog("Starting queue with pools: \(poolURLs)")
        HostResolver.resolve(urls: poolURLs,
                             timeout: config.timeout,
                             maxRetries: config.maxRetries,
                             callbackQueue: queue) { host, result in
            guard self.started && !self.finished else {
                self.debugLog("Got DNS response after queue stopped: \(host), \(result)")
                return
            }
            guard poolURLs == self.poolURLs else {
                self.debugLog("Got DNS response after pool URLs changed: \(host), \(result)")
                return
            }

            switch result {
                case let .Success(addresses):
                    self.queryAddresses(addresses)
                case let .Failure(error):
                    self.finish(.Failure(error))
            }
        }
    }

    func stopQueue() {
        debugLog("Stopping queue")
        startTime = nil
        connections.forEach { $0.close(waitUntilFinished: true) }
        connections = []
    }

    func invalidate() {
        stopQueue()
        finished = false
        currentReferenceTime = nil
    }

    func queryAddresses(addresses: [SocketAddress]) {
        var results: [SocketAddress: [ReferenceTimeResult]] = [:]
        connections = NTPConnection.query(addresses: addresses,
                                          config: config,
                                          callbackQueue: queue) { connection, result in
            guard self.started && !self.finished else {
                self.debugLog("Got NTP response after queue stopped: \(result)")
                return
            }

            if results[connection.address] == nil {
                results[connection.address] = []
            }
            results[connection.address]?.append(result)

            let responses = Array(results.values)
            let responseCount = responses.map { $0.count }.reduce(0, combine: +)
            let expectedCount = addresses.count * self.config.numberOfSamples
            let atEnd = responseCount == expectedCount
            let times = responses.map {
                results in results.map { $0.value }.filter { $0 != nil }.flatMap { $0 }
            }

            self.debugLog("Got \(responseCount) out of \(expectedCount)")
            self.debugLog("Times: \(times)")

            if let time = self.bestTime(fromResponses: times) {
                self.debugLog("Got time: \(time)")
                self.currentReferenceTime = time
                self.updateProgress(.Success(time))
                if atEnd {
                    self.debugLog("Sample size: \(times.flatten().count)")
                    self.finish(.Success((time)))
                }
            } else if atEnd {
                self.finish(result)
            }
        }
    }

    func bestTime(fromResponses times: [[ReferenceTime]]) -> ReferenceTime? {
        let now = timeval.now()
        let bestTimes = times.map { (serverTimes: [ReferenceTime]) -> ReferenceTime? in
            serverTimes.filter { time in
                if let response = time.serverResponse {
                    return abs(response.packet.originate_time.milliseconds -
                               now.milliseconds) < maxResultDispersion
                }
                return false
            }.minElement { $0.serverResponse?.delay < $1.serverResponse?.delay }
        }.filter { $0 != nil }.flatMap { $0 }.sort {
            $0.serverResponse?.offset < $1.serverResponse?.offset
        }

        return bestTimes.isEmpty ? nil : bestTimes[bestTimes.count / 2]
    }

    func updateProgress(result: ReferenceTimeResult) {
        let endTime = CFAbsoluteTimeGetCurrent()
        let hasStartCallbacks = !startCallbacks.isEmpty
        startCallbacks.forEach { queue, callback in
            dispatch_async(queue) {
                callback(result)
            }
        }
        startCallbacks = []
        if hasStartCallbacks {
            logDuration(endTime, to: "get first result")
        }
    }

    func finish(result: ReferenceTimeResult) {
        let endTime = CFAbsoluteTimeGetCurrent()
        updateProgress(result)
        completionCallbacks.forEach { queue, callback in
            dispatch_async(queue) {
                callback(result)
            }
        }
        completionCallbacks = []
        logDuration(endTime, to: "get last result")
        finished = result.value != nil
        stopQueue()
    }

    func logDuration(endTime: CFAbsoluteTime, to description: String) {
        if let startTime = startTime {
            debugLog("Took \(endTime - startTime)s to \(description)")
        }
    }
}

private let maxResultDispersion: Int64 = 10 * Int64(MSEC_PER_SEC)
