# TrueTime for Swift [![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage) [![Travis CI](https://travis-ci.org/instacart/TrueTime.swift.svg?branch=master)](https://travis-ci.org/instacart/TrueTime.swift)

![TrueTime](truetime.png "TrueTime for Swift")

*Make sure to check out our counterpart too: [TrueTime](https://github.com/instacart/truetime-android), an NTP library for Android.*

NTP client for Swift. Calculate the time "now" impervious to manual changes to device clock time.

In certain applications it becomes important to get the real or "true" date and time. On most devices, if the clock has been changed manually, then an `NSDate()` instance gives you a time impacted by local settings.

Users may do this for a variety of reasons, like being in different timezones, trying to be punctual and setting their clocks 5 – 10 minutes early, etc. Your application or service may want a date that is unaffected by these changes and reliable as a source of truth. TrueTime gives you that.

## How is TrueTime calculated?

It's pretty simple actually. We make a request to an NTP server that gives us the actual time. We then establish the delta between device uptime and uptime at the time of the network response. Each time `now()` is requested subsequently, we account for that offset and return a corrected `NSDate` value.

## Usage

### Swift
```swift
import TrueTime

// At an opportune time (e.g. app start):
let client = TrueTimeClient.sharedInstance
client.start()

// You can now use this instead of NSDate():
let now = client.referenceTime?.now()

// To block waiting for fetch, use the following:
client.fetchIfNeeded { result in
    switch result {
        case let .success(referenceTime):
            let now = referenceTime.now()
        case let .failure(error):
            print("Error! \(error)")
    }
}
```
### Objective-C
```objective-c
@import TrueTime;

// At an opportune time (e.g. app start):
TrueTimeClient *client = [TrueTimeClient sharedInstance];
[client startWithPool:@[@"time.apple.com"] port:123];

// You can now use this instead of [NSDate date]:
NSDate *now = [[client referenceTime] now];

// To block waiting for fetch, use the following:
[client fetchIfNeededWithSuccess:^(NTPReferenceTime *referenceTime) {
    NSLog(@"True time: %@", [referenceTime now]);
} failure:^(NSError *error) {
    NSLog(@"Error! %@", error);
}];
```

### Notifications

You can also listen to the `TrueTimeUpdated` notification to detect when a reference time has been fetched:

```swift
let client = TrueTimeClient.sharedInstance
let _ = NSNotificationCenter.default.addObserver(forName: .TrueTimeUpdated, object: client) { _ in
    // Now guaranteed to be non-nil.
    print("Got time: \(client.referenceTime?.now()")
}
```

## Installation Options

TrueTime is currently compatible with iOS 8 and up, macOS 10.10 and tvOS 9.

### [Carthage](https://github.com/Carthage/Carthage) (recommended)

Add this to your `Cartfile`:

```
github "instacart/TrueTime.swift"
```

Then run:
```
$ carthage update
```

### CocoaPods

Add this to your `Podfile`:

```
pod 'TrueTime'
```

Then run:
```
$ pod install
```

### Manually

* Run `git submodule update --init`.
* Run `carthage bootstrap`.
* Run `brew install swiftlint` if not already installed.
* Open `TrueTime.xcodeproj`, choose `TrueTimeExample` and hit run. This will build everything and run the sample app.

### Manually using git submodules

* Add TrueTime as a submodule:

```
$ git submodule add https://github.com/instacart/TrueTime.swift.git
```

* Follow the above instructions for bootstrapping manually.
* Drag `TrueTime.xcodeproj` into the Project Navigator.
* Go to `Project > Targets > Build Phases > Link Binary With Libraries`, click `+` and select the `TrueTime` target.

## Notes / Tips

* Since `NSDates` are just Unix timestamps, it's safe to hold onto values returned by `ReferenceTime.now()` or persist them to disk without having to adjust them later.
* Reachability events are automatically accounted for to pause/start requests.
* UDP requests are executed in parallel, with a default limit of 5 parallel calls. If one fails, we'll retry up to 3 times by default.
* TrueTime is also [available for Android](https://github.com/instacart/truetime-android).

## Contributing

This project adheres to the Contributor Covenant [code of conduct](CODE_OF_CONDUCT.md).
By participating (including but not limited to; reporting issues, commenting on issues and contributing code) you are expected to uphold this code. Please report unacceptable behavior to  opensource@instacart.com.

### Setup

Development depends on some [Carthage](https://github.com/Carthage/Carthage) dependencies and a [xcconfig](https://github.com/jspahrsummers/xcconfigs) git submodule.

Clone the repo and setup dependencies with:

```
git submodule update --init --recursive
carthage bootstrap
```


## License

```
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Learn more

[![NTP](ntp.gif "Read more about the NTP protocol")](https://www.eecis.udel.edu/~mills/ntp/html/index.html)
