//
//  ArbitraryExtensions.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/19/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

@testable import TrueTime
import CTrueTime
import SwiftCheck

extension timeval: Arbitrary {
    public static var arbitrary: Gen<timeval> {
        return Gen<(Int, Int32)>.zip(Int.arbitrary, Int32.arbitrary).map(timeval.init)
    }
}

extension timeval {
    static var arbitraryPositive: Gen<timeval> {
        return arbitrary.suchThat { $0.tv_sec > 0 && $0.tv_usec > 0 }
    }
}
