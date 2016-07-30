# TrueTime for Swift [![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)

SNTP client for Swift. Calculate the time "now" impervious to manual changes to device clock time.

In certain applications it becomes important to get the real or "true" date and time. On most devices, if the clock has been changed manually, then an `NSDate()` instance gives you a time impacted by local settings.

Users may do this for a variety of reasons, like being in different timezones, trying to be punctual and setting their clocks 5 – 10 minutes early, etc. Your application or service may want a date that is unaffected by these changes and reliable as a source of truth. TrueTime gives you that.

## How is TrueTime calculated?

It's pretty simple actually. We make a request to an NTP server that gives us the actual time. We then establish the delta between device uptime and uptime at the time of the network response. Each time `now()` is requested subsequently, we account for that offset and return a corrected `NSDate` value.

## Usage

### Swift
```swift
import TrueTime

let client = SNTPClient.sharedInstance
client.start(hostURLs: [NSURL(string: "time.apple.com")!])
client.retrieveReferenceTime { result in
	switch result {
		case let .Success(referenceTime):
			print("True time: \(referenceTime.now())")
		case let .Failure(error):
			print("Error! \(error)")
	}
}
```
### Objective-C
```objective-c
@import TrueTime;

SNTPClient *client = [SNTPClient sharedInstance];
[client startWithHostURLs:@[[NSURL URLWithString:@"time.apple.com"]]];
[client retrieveReferenceTimeWithSuccess:^(NTPReferenceTime *referenceTime) {
    NSLog(@"True time: %@", [referenceTime now]);
} failure:^(NSError *error) {
    NSLog(@"Error! %@", error);
}];
```

## Installation

TrueTime is currently compatible with iOS 8 and up, macOS 10.9 and tvOS 9.

### [Carthage](https://github.com/Carthage/Carthage)

Add this to your `Cartfile`:

```
github "instacart/TrueTime.swift"
```

Then run:
```
$ carthage update
```

### Manually

* Run `carthage bootstrap`.
* Open `TrueTime.xcodeproj`, choose `TrueTimeExample` and hit run. This will build everything and run the sample app.

### Manually using submodules

* Add TrueTime as a submodule:

```
$ git submodule add https://github.com/instacart/TrueTime.swift.git
```

* Drag `TrueTime.xcodeproj` into the Project Navigator
* Go to `Project > Targets > Build Phases > Link Binary With Libraries`, click `+` and select the `TrueTime` target.

## Notes / Tips
* Since `NSDates` are just Unix timestamps, it's safe to hold onto values returned by `ReferenceTime.now()` or persist them to disk without having to adjust them later.
* Reachability events are automatically accounted for to pause/start requests.
* TrueTime was built to be accurate "enough", hence the use of [SNTP](https://en.wikipedia.org/wiki/Network_Time_Protocol#SNTP). If you need exact millisecond accuracy then you probably want [NTP](https://www.meinbergglobal.com/english/faq/faq_37.htm) (i.e. SNTP + statistical analysis to ensure the reference time is exactly correct). TrueTime provides the building blocks for this — we welcome PRs if you you'd like to make this change.

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
