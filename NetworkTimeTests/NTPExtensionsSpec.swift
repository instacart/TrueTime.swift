//
//  NTPExtensionsSpec.swift
//  NetworkTime
//
//  Created by Michael Sanders on 7/18/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

@testable import NetworkTime
import CNetworkTime
import Nimble
import Quick
import SwiftCheck

final class NTPExtensionsSpec: QuickSpec {
    override func spec() {
        it("ntp_time_t") {
            property("Matches timeval precision") <- forAll(timeval.arbitraryPositive) { time in
                let ntp = ntp_time_t(time)
                return ntp.milliseconds == time.milliseconds
            }
        }
    }
}
