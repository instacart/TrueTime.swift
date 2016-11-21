Pod::Spec.new do |s|
  s.name = 'TrueTime'
  s.version = '3.1.0'
  s.summary = 'NTP library for Swift. Get the true time impervious to device clock changes.'

  s.homepage = 'https://github.com/instacart/TrueTime.swift'
  s.license = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.author = { 'Michael Sanders' => 'msanders@instacart.com' }
  s.source = { :git => 'https://github.com/instacart/TrueTime.swift.git', :tag => s.version }

  s.requires_arc = true
  s.ios.deployment_target = '8.0'
  s.osx.deployment_target = '10.9'
  s.tvos.deployment_target = '9.0'

  s.source_files = 'Sources/*.{swift,h,m}', 'Sources/CTrueTime/*.h'
  s.public_header_files = 'Sources/*.h'
  s.pod_target_xcconfig = { 'SWIFT_INCLUDE_PATHS' => '$(SRCROOT)/TrueTime/Sources/CTrueTime/**' }
  s.preserve_paths  = 'Sources/CTrueTime/module.modulemap'
  s.dependency 'Result', '~> 3.0'
end
