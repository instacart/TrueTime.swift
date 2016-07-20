//
//  ArbitraryExtensions.swift
//  NetworkTime
//
//  Created by Michael Sanders on 7/19/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CNetworkTime
import Curry
import SwiftCheck

extension timeval: Arbitrary {
    public static var arbitrary: Gen<timeval> {
        return curry(timeval.init) <^> Int.arbitrary <*> Int32.arbitrary
    }
}

extension ntp_time_t: Arbitrary {
    public static var arbitrary: Gen<ntp_time_t> {
        return curry(ntp_time_t.init) <^> UInt32.arbitrary <*> UInt32.arbitrary
    }
}

extension timeval {
    static var arbitraryPositive: Gen<timeval> {
        return arbitrary.suchThat { $0.tv_sec > 0 && $0.tv_usec > 0 }
    }
}
