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
    let timeout: TimeInterval
    let maxRetries: Int
    let maxConnections: Int
    let maxServers: Int
    let numberOfSamples: Int
    let pollInterval: TimeInterval
}

final class NTPClient {
    let config: NTPConfig
    init(config: NTPConfig) {
        self.config = config
    }

    func start(pools poolURLs: [URL]) {
        precondition(!poolURLs.isEmpty, "Must include at least one pool URL")
        queue.async {
            precondition(self.reachability.callback == nil, "Already started")
            self.poolURLs = poolURLs
            self.reachability.callbackQueue = self.queue
            self.reachability.callback = self.updateReachability
            self.reachability.startMonitoring()
            self.startTimer()
        }
    }

    func pause() {
        queue.async {
            self.cancelTimer()
            self.reachability.stopMonitoring()
            self.stopQueue()
        }
    }

    func fetchIfNeeded(queue callbackQueue: DispatchQueue,
                       first: ReferenceTimeCallback?,
                       completion: ReferenceTimeCallback?) {
        queue.async {
            precondition(self.reachability.callback != nil,
                         "Must start client before retrieving time")
            if let time = self.referenceTime {
                callbackQueue.async { first?(.success(time)) }
            } else if let first = first {
                self.startCallbacks.append((callbackQueue, first))
            }

            if let time = self.referenceTime, self.finished {
                callbackQueue.async { completion?(.success(time)) }
            } else {
                if let completion = completion {
                    self.completionCallbacks.append((callbackQueue, completion))
                }
                self.updateReachability(status: self.reachability.status ?? .notReachable)
            }
        }
    }

    private let referenceTimeLock: GCDLock<ReferenceTime?> = GCDLock(value: nil)
    var referenceTime: ReferenceTime? {
        get { return referenceTimeLock.read() }
        set { referenceTimeLock.write(newValue) }
    }

    fileprivate func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG_LOGGING
        logger?(message())
#endif
    }

    var logger: LogCallback? = defaultLogger
    fileprivate let queue = DispatchQueue(label: "com.instacart.ntp.client")
    fileprivate let reachability = Reachability()
    fileprivate var completionCallbacks: [(DispatchQueue, ReferenceTimeCallback)] = []
    fileprivate var connections: [NTPConnection] = []
    fileprivate var finished: Bool = false
    fileprivate var invalidated: Bool = false
    fileprivate var startCallbacks: [(DispatchQueue, ReferenceTimeCallback)] = []
    fileprivate var startTime: TimeInterval?
    fileprivate var timer: DispatchSourceTimer?
    fileprivate var poolURLs: [URL] = [] {
        didSet { invalidate() }
    }
}

private extension NTPClient {
    var started: Bool { return startTime != nil }
    func updateReachability(status: ReachabilityStatus) {
        switch status {
            case .notReachable:
                debugLog("Network unreachable")
                cancelTimer()
                finish(.failure(NSError(trueTimeError: .offline)))
            case .reachableViaWWAN, .reachableViaWiFi:
                debugLog("Network reachable")
                startTimer()
                startQueue(poolURLs: poolURLs)
        }
    }

    func startTimer() {
        cancelTimer()
        if let referenceTime = referenceTime {
            let remainingInterval = max(0, config.pollInterval -
                                           referenceTime.underlyingValue.uptimeInterval)
            timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
            timer?.setEventHandler(handler: invalidate)
            timer?.scheduleOneshot(deadline: .now() + remainingInterval)
            timer?.resume()
        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    func startQueue(poolURLs: [URL]) {
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
                case let .success(addresses):
                    self.query(addresses: addresses, pool: host.url)
                case let .failure(error):
                    self.finish(.failure(error))
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
        if let referenceTime = referenceTime,
               reachability.status != .notReachable && !poolURLs.isEmpty {
            debugLog("Invalidated time \(referenceTime.debugDescription)")
            startQueue(poolURLs: poolURLs)
        }
    }

    func query(addresses: [SocketAddress], pool: URL) {
        var results: [String: [FrozenNetworkTimeResult]] = [:]
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
            let sampleSize = responses.map { $0.count }.reduce(0, +)
            let expectedCount = addresses.count * self.config.numberOfSamples
            let atEnd = sampleSize == expectedCount
            let times = responses.map { results in
                results.map { $0.value }.flatMap { $0 }
            }

            self.debugLog("Got \(sampleSize) out of \(expectedCount)")
            if let time = bestTime(fromResponses: times) {
                let time = FrozenNetworkTime(networkTime: time,
                                             sampleSize: sampleSize,
                                             pool: pool)
                self.debugLog("\(atEnd ? "Final" : "Best") time: \(time), " +
                              "δ: \(time.serverResponse.delay), " +
                              "θ: \(time.serverResponse.offset)")

                let referenceTime = self.referenceTime ?? ReferenceTime(time)
                if self.referenceTime == nil {
                    self.referenceTime = referenceTime
                } else {
                    referenceTime.underlyingValue = time
                }

                if atEnd {
                    self.finish(.success(referenceTime))
                } else {
                    self.updateProgress(.success(referenceTime))
                }
            } else if atEnd {
                self.finish(.failure(result.error ?? NSError(trueTimeError: .noValidPacket)))
            }
        }
    }

    func updateProgress(_ result: ReferenceTimeResult) {
        let endTime = CFAbsoluteTimeGetCurrent()
        let hasStartCallbacks = !startCallbacks.isEmpty
        startCallbacks.forEach { queue, callback in
            queue.async {
                callback(result)
            }
        }
        startCallbacks = []
        if hasStartCallbacks {
            logDuration(endTime, to: "get first result")
        }

        NotificationCenter.default.post(Notification(name: .TrueTimeUpdated, object: self, userInfo: nil))
    }

    func finish(_ result: ReferenceTimeResult) {
        let endTime = CFAbsoluteTimeGetCurrent()
        updateProgress(result)
        completionCallbacks.forEach { queue, callback in
            queue.async {
                callback(result)
            }
        }
        completionCallbacks = []
        logDuration(endTime, to: "get last result")
        finished = result.value != nil
        stopQueue()
        startTimer()
    }

    func logDuration(_ endTime: CFAbsoluteTime, to description: String) {
        if let startTime = startTime {
            debugLog("Took \(endTime - startTime)s to \(description)")
        }
    }
}
