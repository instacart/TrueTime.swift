//
//  NTPIntegrationSpec.swift
//  TrueTime
//
//  Created by Michael Sanders on 8/1/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

@testable import TrueTime
import Nimble
import Quick
import Result

final class NTPIntegrationSpec: QuickSpec {
    override func spec() {
        describe("retrieveReferenceTime") {
            it("should ignore outliers") {
                self.testReferenceTimeOutliers()
            }
        }
    }
}

private extension NTPIntegrationSpec {
    func testReferenceTimeOutliers() {
        let clients = (0..<100).map { _ in TrueTimeClient() }
        waitUntil(timeout: 60) { done in
            var results: [ReferenceTimeResult?] = Array(repeating: nil, count: clients.count)
            let start = NSDate()
            let finish = {
                let end = NSDate()
                let results = results.filter { $0 != nil }.flatMap { $0 }
                let times = results.filter { $0.value != nil }.map { $0.value! }
                let errors = results.filter { $0.error != nil }.map { $0.error! }
                expect(times).notTo(beEmpty(), description: "Expected times, got: \(errors)")
                print("Got \(times.count) times for \(results.count) results")

                let sortedTimes = times.sorted {
                    $0.time.timeIntervalSince1970 < $1.time.timeIntervalSince1970
                }

                if !sortedTimes.isEmpty {
                    let medianTime = sortedTimes[sortedTimes.count / 2]
                    let maxDelta = end.timeIntervalSince1970 - start.timeIntervalSince1970
                    for time in times {
                        let delta = abs(time.time.timeIntervalSince1970 -
                                        medianTime.time.timeIntervalSince1970)
                        expect(delta) <= maxDelta
                    }
                }

                done()
            }

            for (idx, client) in clients.enumerated() {
                client.start(hostURLs: [URL(string: "time.apple.com")!])
                client.retrieveReferenceTime { result in
                    results[idx] = result
                    if !results.contains(where: { $0 == nil }) {
                        finish()
                    }
                }
            }
        }
    }
}
