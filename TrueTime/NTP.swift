//
//  NTP.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation
import Result

public enum SNTPClientError: ErrorType {
    case UnresolvableHost(underlyingError: CFStreamError?)
    case ConnectionError(underlyingError: NSError?)
}

public struct ReferenceTime {
    public let time: NSDate
    public let uptime: timeval
}

public extension ReferenceTime {
    func now() -> NSDate {
        let currentUptime = timeval.uptime()
        let interval = NSTimeInterval(milliseconds: currentUptime.milliseconds -
                                                    uptime.milliseconds)
        return time.dateByAddingTimeInterval(interval)
    }
}

public typealias ReferenceTimeCallback = Result<ReferenceTime, SNTPClientError> -> Void

@objc public final class SNTPClient: NSObject {
    public static let sharedInstance = SNTPClient()
    public let timeout: NSTimeInterval
    required public init(timeout: NSTimeInterval = defaultTimeout) {
        self.timeout = timeout
    }

    public func start(hostURLs hostURLs: [NSURL]) {
        reachability.callbackQueue = queue
        reachability.callback = { [weak self] status in
            guard let strongSelf = self else { return }
            switch status {
                case .NotReachable:
                    debugLog("Network unreachable")
                    strongSelf.pauseQueue()
                case .ReachableViaWWAN, .ReachableViaWiFi:
                    debugLog("Network reachable")
                    strongSelf.startQueue(hostURLs: hostURLs)
            }
        }

        reachability.startMonitoring()
    }

    public func pause() {
        reachability.stopMonitoring()
        pauseQueue()
    }

    public func retrieveReferenceTime(callback: ReferenceTimeCallback) {
        dispatch_async(queue) {
            guard let referenceTime = self.referenceTime else {
                if !self.reachability.online {
                    callback(.Failure(.ConnectionError(underlyingError: .offlineError)))
                } else {
                    self.callbacks.append(callback)
                    if self.results.count == self.hosts.count && self.results.count > 0 {
                        self.startQueue(hostURLs: self.hostURLs) // Retry if we failed last time.
                    }
                }
                return
            }

            callback(.Success(referenceTime))
        }
    }

    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-client", nil)
    private let reachability = Reachability()
    private var callbacks: [ReferenceTimeCallback] = []
    private var hostURLs: [NSURL] = []
    private var hosts: [SNTPHost] = []
    private var referenceTime: ReferenceTime?
    private var results: [Result<ReferenceTime, SNTPClientError>] = []
    private var startTime: NSTimeInterval?
}

// MARK: - Objective-C Bridging

@objc public final class NTPReferenceTime: NSObject {
    init(referenceTime: ReferenceTime) {
        self.underlyingValue = referenceTime
    }

    public let underlyingValue: ReferenceTime
    public var time: NSDate { return underlyingValue.time }
    public var uptime: timeval { return underlyingValue.uptime }
    public func now() -> NSDate { return underlyingValue.now() }
}

extension SNTPClient {
    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?) {
        retrieveReferenceTime { result in
            switch result {
                case let .Success(time):
                    success(NTPReferenceTime(referenceTime: time))
                case let .Failure(error):
                    failure?(error.bridged)
            }
        }
    }
}

private let bridgedErrorDomain = "com.instacart.sntp-client-error"
private extension SNTPClientError {
    var bridged: NSError {
        switch self {
            case let .ConnectionError(underlyingError):
                if let underlyingError = underlyingError {
                    return underlyingError
                }
            default:
                break
        }

        let (code, description) = metadata
        return NSError(domain: bridgedErrorDomain,
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: description])
    }

    var metadata: (Int, String) {
        switch self {
            case .UnresolvableHost:
                return (1, "Unresolvable host name.")
            case .ConnectionError:
                return (2, "Failed connecting to NTP server.")
        }
    }
}

// MARK: -

private extension SNTPClient {
    func startQueue(hostURLs hostURLs: [NSURL]) {
        dispatch_async(queue) {
            guard self.hostURLs != hostURLs && self.referenceTime == nil else {
                debugLog("Already \(self.referenceTime == nil ? "started" : "finished")")
                return
            }

            debugLog("Starting queue with hosts: \(hostURLs)")
            self.startTime = CFAbsoluteTimeGetCurrent()
            self.hostURLs = hostURLs
            self.hosts = hostURLs.map { url in  SNTPHost(hostURL: url,
                                                         timeout: self.timeout,
                                                         onComplete: self.onComplete) }
            self.hosts.forEach { $0.start() }
        }
    }

    func pauseQueue() {
        dispatch_async(queue) {
            debugLog("Pausing queue")
            self.hosts.forEach { $0.close() }
            self.hostURLs = []
            self.startTime = nil
        }
    }

    func onComplete(result: Result<ReferenceTime, SNTPClientError>) {
        dispatch_async(queue) {
            self.results.append(result)
            switch result {
                case let .Success(referenceTime):
                    self.referenceTime = referenceTime
                    fallthrough
                case .Failure where self.results.count == self.hosts.count:
                    let endTime = CFAbsoluteTimeGetCurrent()
                    debugLog("\(self.results.count) results: \(self.results)")
                    debugLog("Took \(endTime - self.startTime!)s")
                    self.hosts.forEach { $0.close() }
                    self.callbacks.forEach { $0(result) }
                    self.callbacks = []
                default:
                    break
            }
        }
    }
}

private let defaultTimeout: NSTimeInterval = 5
