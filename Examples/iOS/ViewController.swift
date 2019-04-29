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
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(startTimer),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cancelTimer),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        label.frame = view.bounds.insetBy(dx: 15, dy: 15)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        startTimer()

    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelTimer()
    }

    fileprivate var referenceTime: ReferenceTime?
    fileprivate var timer: Timer?
    fileprivate lazy var label: UILabel = {
        let label = UILabel()
        label.textColor = .black
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        return label
    }()
}

private extension ExampleViewController {
    @objc func startTimer() {
        timer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
            label.text = "\(trueTime)\n\n\(referenceTime)"
        }
    }

    func refresh() {
        TrueTimeClient.sharedInstance.fetchIfNeeded { result in
            switch result {
            case let .success(referenceTime):
                self.referenceTime = referenceTime
                print("Got network time! \(referenceTime)")
            case let .failure(error):
                print("Error! \(error)")
            }
        }
    }
}
