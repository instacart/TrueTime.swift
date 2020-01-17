Pod::Spec.new do |s|
  s.name = 'TrueTime'
  s.version = '5.1.0'
  s.summary = 'NTP library for Swift. Get the true time impervious to device clock changes.'

  s.homepage = 'https://github.com/instacart/TrueTime.swift'
  s.license = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.author = { 'Michael Sanders' => 'msanders@instacart.com' }
  s.source = { :git => 'https://github.com/instacart/TrueTime.swift.git', :tag => s.version }
  s.swift_version = '5.0'

  s.requires_arc = true
  s.ios.deployment_target = '8.0'
  s.osx.deployment_target = '10.10'
  s.tvos.deployment_target = '9.0'

  s.source_files = 'Sources/**/*.{swift,h,m}'
  s.public_header_files = 'Sources/**/*.h'
end
