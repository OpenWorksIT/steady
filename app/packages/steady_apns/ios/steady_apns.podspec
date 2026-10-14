Pod::Spec.new do |s|
  s.name             = 'steady_apns'
  s.version          = '0.1.0'
  s.summary          = 'Minimal APNs bridge for Steady.'
  s.description      = 'Requests notification permission, returns the APNs device token and reports taps. No Firebase.'
  s.homepage         = 'https://github.com/openworksIT/steady'
  s.license          = { :type => 'AGPL-3.0-or-later' }
  s.author           = { 'OpenWorks IT' => 'https://openworks.co.za' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
