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
        dispatch_async(queue) {
            precondition(self.reachability.callback == nil, "Already started")
            self.poolURLs = poolURLs
            self.reachability.callbackQueue = self.queue
            self.reachability.callback = self.updateReachability
            self.reachability.startMonitoring()
            self.startTimer()
        }
    }

    func pause() {
        dispatch_async(queue) {
            self.cancelTimer()
            self.reachability.stopMonitoring()
            self.stopQueue()
        }
    }

    func fetchIfNeeded(queue callbackQueue: dispatch_queue_t,
                       first: ReferenceTimeCallback?,
                       completion: ReferenceTimeCallback?) {
        dispatch_async(queue) {
            precondition(self.reachability.callback != nil,
                         "Must start client before retrieving time")
            if let time = self.referenceTime {
                dispatch_async(callbackQueue) {
                    first?(.Success(time))
                }
            } else if let first = first {
                self.startCallbacks.append((callbackQueue, first))
            }

            if let time = self.referenceTime where self.finished {
                dispatch_async(callbackQueue) {
                    completion?(.Success(time))
                }
            } else {
                if let completion = completion {
                    self.completionCallbacks.append((callbackQueue, completion))
                }
                self.updateReachability(status: self.reachability.status ?? .NotReachable)
            }
        }
    }

    private let referenceTimeLock: GCDLock<ReferenceTime?> = GCDLock(value: nil)
    var referenceTime: ReferenceTime? {
        get { return referenceTimeLock.read() }
        set { referenceTimeLock.write(newValue) }
    }

    private func debugLog(@autoclosure message: () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    var logger: LogCallback? = defaultLogger
    private var timer: dispatch_source_t?
    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.ntp.client", nil)
    private let reachability = Reachability()
    private var completionCallbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var connections: [NTPConnection] = []
    private var invalidated: Bool = false
    private var finished: Bool = false
    private var startCallbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var startTime: NSTimeInterval?
    private var poolURLs: [NSURL] = [] {
        didSet {
            invalidate()
        }
    }
}

private extension NTPClient {
    var started: Bool { return startTime != nil }
    func updateReachability(status status: ReachabilityStatus) {
        switch status {
            case .NotReachable:
                debugLog("Network unreachable")
                cancelTimer()
                finish(.Failure(NSError(trueTimeError: .Offline)))
            case .ReachableViaWWAN, .ReachableViaWiFi:
                debugLog("Network reachable")
                startTimer()
                startQueue(poolURLs: poolURLs)
        }
    }

    func startTimer() {
        cancelTimer()
        if let referenceTime = referenceTime {
            let remainingInterval = max(0, referenceTime.maxUptimeInterval -
                                           referenceTime.uptimeInterval)
            timer = dispatchTimer(after: remainingInterval, queue: queue, block: invalidate)

        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    func startQueue(poolURLs poolURLs: [NSURL]) {
        guard !started && !finished else {
            debugLog("Already \(started ? "started" : "finished")")
            return
        }

        startTime = CFAbsoluteTimeGetCurrent()
        debugLog("Resolving pool: \(poolURLs)")
        HostResolver.resolve(urls: poolURLs,
                             timeout: config.timeout,
                             logger: logger,
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
                    self.query(addresses: addresses, pool: host.url)
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
        if let referenceTime = referenceTime where reachability.status != .NotReachable &&
                                                   !poolURLs.isEmpty {
            debugLog("Invalidated time \(referenceTime.debugDescription)")
            startQueue(poolURLs: poolURLs)
        }
    }

    func query(addresses addresses: [SocketAddress], pool: NSURL) {
        var results: [String: [FrozenReferenceTimeResult]] = [:]
        connections = NTPConnection.query(addresses: addresses,
                                          config: config,
                                          logger: logger,
                                          callbackQueue: queue) { connection, result in
            guard self.started && !self.finished else {
                self.debugLog("Got NTP response after queue stopped: \(result)")
                return
            }

            let host = connection.address.host
            results[host] = (results[host] ?? []) + [result]

            let responses = Array(results.values)
            let sampleSize = responses.map { $0.count }.reduce(0, combine: +)
            let expectedCount = addresses.count * self.config.numberOfSamples
            let atEnd = sampleSize == expectedCount
            let times = responses.map {
                results in results.map { $0.value }.filter { $0 != nil }.flatMap { $0 }
            }

            self.debugLog("Got \(sampleSize) out of \(expectedCount)")
            if let time = bestTime(fromResponses: times) {
                let time = FrozenReferenceTime(referenceTime: time,
                                               sampleSize: sampleSize,
                                               pool: pool)
                self.debugLog("\(atEnd ? "Final" : "Best") time: \(time), " +
                              "δ: \(time.serverResponse?.delay ?? 0), " +
                              "θ: \(time.serverResponse?.offset ?? 0)")

                let referenceTime = self.referenceTime ?? ReferenceTime(time)
                if self.referenceTime == nil {
                    self.referenceTime = referenceTime
                } else {
                    referenceTime.underlyingValue = time
                }

                self.updateProgress(.Success(referenceTime))
                if atEnd {
                    self.finish(.Success(referenceTime))
                }
            } else if atEnd {
                self.finish(.Failure(result.error ?? NSError(trueTimeError: .NoValidPacket)))
            }
        }
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
        startTimer()
    }

    func logDuration(endTime: CFAbsoluteTime, to description: String) {
        if let startTime = startTime {
            debugLog("Took \(endTime - startTime)s to \(description)")
        }
    }
}
