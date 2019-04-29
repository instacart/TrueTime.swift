//
//  AppDelegate.swift
//  NTPExample
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import UIKit
import TrueTime

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        TrueTimeClient.sharedInstance.start()
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .white
        window?.makeKeyAndVisible()
        window?.rootViewController = ExampleViewController()
        return true
    }
}
