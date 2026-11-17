#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_daemon.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_daemon'
  s.version          = '0.0.1'
  s.summary          = 'Run processes in the background'
  s.description      = <<-DESC
Run Dart code at specified intervals, even when the app is not in the foreground.
                       DESC
  s.homepage         = 'https://github.com/MrCyjaneK/flutter_daemon'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'MrCyjaneK' => 'https://github.com/MrCyjaneK' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
