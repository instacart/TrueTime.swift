//
//  AppDelegate.swift
//  NTPExample
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import UIKit
import Result
import TrueTime

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
        let client = SNTPClient.sharedInstance
        client.start(hostURLs: [
            NSURL(string: "time.apple.com")!,
            NSURL(string: "clock.sjc.he.net")!,
            NSURL(string: "0.north-america.pool.ntp.org")!,
            NSURL(string: "1.north-america.pool.ntp.org")!,
            NSURL(string: "2.north-america.pool.ntp.org")!,
            NSURL(string: "3.north-america.pool.ntp.org")!,
            NSURL(string: "0.us.pool.ntp.org")!,
            NSURL(string: "1.us.pool.ntp.org")!,
        ])

        client.retrieveReferenceTime { result in
            switch result {
                case let .Success(referenceTime):
                    print("Got network time! \(referenceTime.time)s")
                case let .Failure(error):
                    print("Error! \(error)")
            }
        }

        self.window = UIWindow(frame: UIScreen.mainScreen().bounds)
        self.window?.backgroundColor = UIColor.whiteColor()
        self.window?.makeKeyAndVisible()
        self.window?.rootViewController = UIViewController()
        return true
    }
}
