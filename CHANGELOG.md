# Changelog

All notable changes to this project will be documented in this file.
`TrueTime.swift` adheres to [Semantic Versioning](http://semver.org/).

## [4.1.1](https://github.com/instacart/TrueTime.swift/releases/tag/4.1.1)

- Fixed: Addressed issue building project with latest swiftlint installed.

## [4.1.0](https://github.com/instacart/TrueTime.swift/releases/tag/4.1.0)

- Added: Now posting notification when reference time gets updated
- Fixed: Fixed crash when receiving empty packets from certain hosts.

## [4.0.0](https://github.com/instacart/TrueTime.swift/releases/tag/4.0.0)

- Added: Swift 3 support.
- Added: Support for configuring polling interval.
- Changed: `retrieveReferenceTime` has been renamed to `fetchIfNeeded`.
- Changed: Dropped support for Mac OS 10.9.

## [3.1.1](https://github.com/instacart/TrueTime.swift/releases/tag/3.1.1)

- Fixed: Addressed issue building project with latest swiftlint installed.

## [3.1.0](https://github.com/instacart/TrueTime.swift/releases/tag/3.1.0)

- Added: Now supporting CocoaPods.

## [3.0.0](https://github.com/instacart/TrueTime.swift/releases/tag/3.0.0)

- Added: Now polls at regular intervals and automatically updates reference
  times.
- Fixed: Addressed assertion getting hit on certain devices when requesting
  network time. 

## [2.1.1](https://github.com/instacart/TrueTime.swift/releases/tag/2.1.1)

- Fixed: Addressed memory leak due to long interpolated strings in Swift 2.3.
- Fixed: Updated dispersion check and uptime function for more accurate times.

## [2.1.0](https://github.com/instacart/TrueTime.swift/releases/tag/2.1.0)

- Added: Now supporting full NTP integration.
- Fixed: Fixed rare crash when resolving hosts.

## [2.0.0](https://github.com/instacart/TrueTime.swift/releases/tag/2.0.0)

- Added: Now supporting Xcode 8 and Swift 2.3.
- Fixed: Fixed bundle identifier for tvOS framework.

## [1.1.0](https://github.com/instacart/TrueTime.swift/releases/tag/1.1.0)

- Fixed: Updated guard for outlier server responses to be more stringent.
- Added: IPv6 support.

## [1.0.1](https://github.com/instacart/TrueTime.swift/releases/tag/1.0.1)

- Fixed: Addresses issue when cloning submodules.

## [1.0.0](https://github.com/instacart/TrueTime.swift/releases/tag/1.0.0)

- Initial release
