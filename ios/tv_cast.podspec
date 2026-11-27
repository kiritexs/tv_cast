#
# CocoaPods fallback for tv_cast's iOS side; Swift Package Manager uses
# tv_cast/Package.swift.
#
Pod::Spec.new do |s|
  s.name             = 'tv_cast'
  s.version          = '0.1.0'
  s.summary          = 'AirPlay and the DLNA search for casting to a TV, on iOS.'
  s.description      = <<-DESC
The iOS side of tv_cast: whether the player's video goes to an AirPlay
device, the system's AirPlay button, and the DLNA search over iOS's own
sockets.
                       DESC
  s.homepage         = 'https://kiritex.com'
  s.license          = { :type => 'MPL-2.0', :file => '../LICENSE' }
  s.author           = 'Kiritex'
  s.source           = { :path => '.' }
  s.source_files = 'tv_cast/Sources/tv_cast/**/*.swift'
  s.dependency 'Flutter'
  s.resource_bundles = { 'tv_cast_privacy' => ['tv_cast/Sources/tv_cast/PrivacyInfo.xcprivacy'] }
  s.frameworks = 'AVFoundation', 'AVKit'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
