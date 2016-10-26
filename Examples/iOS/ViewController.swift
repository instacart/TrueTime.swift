//
//  ViewController.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/26/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import UIKit
import TrueTime

final class ExampleViewController: UIViewController {
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: NSBundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        NSNotificationCenter.defaultCenter().addObserver(
            self,
            selector: #selector(startTimer),
            name: UIApplicationDidBecomeActiveNotification,
            object: nil
        )
        NSNotificationCenter.defaultCenter().addObserver(
            self,
            selector: #selector(cancelTimer),
            name: UIApplicationWillResignActiveNotification,
            object: nil
        )
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        label.frame = view.bounds.insetBy(dx: 15, dy: 15)
        label.autoresizingMask = [.FlexibleWidth, .FlexibleHeight]
        view.addSubview(label)
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        startTimer()

    }

    override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        cancelTimer()
    }

    private var referenceTime: ReferenceTime?
    private var timer: NSTimer?
    private lazy var label: UILabel = {
        let label = UILabel()
        label.textColor = .blackColor()
        label.textAlignment = .Center
        label.font = UIFont.systemFontOfSize(14)
        label.numberOfLines = 0
        return label
    }()
}

private extension ExampleViewController {
    @objc func startTimer() {
        timer = NSTimer.scheduledTimerWithTimeInterval(0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    @objc func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        if let referenceTime = referenceTime {
            let trueTime = referenceTime.now()
            label.text = "\(trueTime)\n\n\(referenceTime.debugDescription)"
        }
    }

    func refresh() {
        TrueTimeClient.sharedInstance.retrieveReferenceTime { result in
            switch result {
                case let .Success(referenceTime):
                    self.referenceTime = referenceTime
                    print("Got network time! \(referenceTime.debugDescription)")
                case let .Failure(error):
                    print("Error! \(error)")
            }
        }
    }
}
