# Google ML Kit Digital Ink Recognition (handwriting, zh-Hani-TW): linked by the keyboard extension, and by the host
# app, which downloads the model. ML Kit ships no arm64 iOS Simulator slice, so everything that links or finds it is
# made device-only in post_install; Simulator builds compile the stubs (`#if canImport(MLKitDigitalInkRecognition)`).
# Run `xcodegen generate` and then `pod install`; build with `-workspace RemoteKeyboard.xcworkspace`.
platform :ios, '18.0'
project 'RemoteKeyboard.xcodeproj'
use_frameworks! :linkage => :static

# The extension needs a host target, so the app is declared too (and links ML Kit for the model download).
target 'RemoteKeyboardApp' do
  pod 'GoogleMLKit/DigitalInkRecognition'
end

target 'RemoteKeyboardExtension' do
  pod 'GoogleMLKit/DigitalInkRecognition'
end

# xcconfig settings that make a target find or link the pods. They get an `[sdk=iphoneos*]` condition.
DEVICE_ONLY_SETTINGS = %w[
  FRAMEWORK_SEARCH_PATHS HEADER_SEARCH_PATHS OTHER_LDFLAGS OTHER_MODULE_VERIFIER_FLAGS
].freeze

post_install do |installer|
  # The pods declare deployment targets from 9.0 to 12.0, which Xcode 27 rejects.
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    end
  end

  Dir.glob("#{installer.sandbox.root}/Target Support Files/**/*.xcconfig").each do |path|
    original = File.read(path)
    lines = original.lines
    # The pod xcconfigs exclude arm64 for the Simulator; the pods that are really built (source pods) can build there.
    lines = lines.reject { |line| line.start_with?('EXCLUDED_ARCHS[sdk=iphonesimulator*]') }
    # The app and extension must not search for or link ML Kit in the Simulator (no arm64 slice).
    if File.basename(path).start_with?('Pods-')
      lines = lines.map do |line|
        key = line[/\A([A-Z_]+) =/, 1]
        DEVICE_ONLY_SETTINGS.include?(key) ? line.sub(/\A#{key}/, "#{key}[sdk=iphoneos*]") : line
      end
    end
    File.write(path, lines.join) if lines.join != original
  end
end
