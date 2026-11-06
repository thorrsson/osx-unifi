require 'openssl'
require 'base64'
require 'fileutils'
require 'open3'
require 'json'

Dir.chdir(File.expand_path('..', __dir__))
def run!(environment, *arguments)
  output, status = Open3.capture2e(environment, *arguments)
  puts output
  abort "error: packaging smoke check failed: #{arguments.first(2).join(' ')}" unless status.success?
end

# Synthetic throwaway keys exercise the full Sparkle packaging contract without
# reading a release key or touching Keychain. Never publish these test artifacts.
key = OpenSSL::PKey.generate_key('ED25519')
environment = {
  'UNIFI_PACKAGING_SMOKE' => '1',
  'UNIFI_UNIVERSAL' => '1',
  'UNIFI_SIGNING_IDENTITY' => '-',
  'UNIFI_SIGNING_KEYCHAIN' => nil,
  'UNIFI_SPARKLE_FEED_URL' => 'https://example.invalid/appcast.xml',
  'UNIFI_SPARKLE_PUBLIC_ED_KEY' => Base64.strict_encode64(key.public_to_der.byteslice(-32, 32)),
  'SPARKLE_PRIVATE_KEY' => Base64.strict_encode64(key.private_to_der.byteslice(-32, 32))
}
fixture = '.build/packaging-smoke'
abort 'error: packaging fixture directory already exists; inspect it before rerunning.' if File.exist?(fixture)
begin
  run!(environment, 'bash', 'Scripts/build-app.sh', '0.1.0')
  run!(environment, 'lipo', "#{fixture}/UniFi Desktop.app/Contents/MacOS/UniFiDesktop", '-verify_arch', 'arm64', 'x86_64')
  contents = "#{fixture}/UniFi Desktop.app/Contents"
  %w[Assets.car AppIcon.icns].each do |resource|
    abort "error: packaged app is missing #{resource}." unless File.file?("#{contents}/Resources/#{resource}")
  end
  %w[CFBundleIconName CFBundleIconFile].each do |key|
    value, status = Open3.capture2('plutil', '-extract', key, 'raw', '-o', '-', "#{contents}/Info.plist")
    abort "error: packaged Info.plist does not name the app icon (#{key})." unless status.success? && value.strip == 'AppIcon'
  end
  puts 'App icon resources and Info.plist keys verified.'
  run!(environment, 'bash', 'Scripts/make-dmg.sh', '0.1.0')
  run!(environment, 'bash', 'Scripts/generate-appcast.sh', '0.1.0')
  puts 'Sparkle appcast generation and embedded-key signature verification passed.'
  run!(environment.merge('UNIFI_SPARKLE_PUBLIC_ED_KEY' => ''), 'bash', 'Scripts/build-app.sh', '0.1.0')
  plist, status = Open3.capture2e('plutil', '-convert', 'json', '-o', '-', "#{contents}/Info.plist")
  abort "error: could not read local-only app configuration: #{plist}" unless status.success?
  settings = JSON.parse(plist)
  abort 'error: local-only app unexpectedly enables Sparkle updates.' if settings.keys.any? { |name| name.start_with?('SU') }
  puts 'Explicitly empty public key disables updates despite the committed public key.'
  store_environment = environment.merge('UNIFI_APP_STORE_SIGNING_IDENTITY' => nil, 'UNIFI_APP_STORE_PROFILE' => nil)
  run!(store_environment, 'bash', 'Scripts/build-app-store.sh', '0.1.0')
  store = "#{fixture}/Lanyard.app/Contents"
  run!(store_environment, 'lipo', "#{store}/MacOS/UniFiDesktop", '-verify_arch', 'arm64', 'x86_64')
  plist, status = Open3.capture2e('plutil', '-convert', 'json', '-o', '-', "#{store}/Info.plist")
  abort "error: could not read App Store Info.plist: #{plist}" unless status.success?
  settings = JSON.parse(plist)
  expected = { 'CFBundleIdentifier' => 'com.thorrsson.lanyard', 'CFBundleDisplayName' => 'Lanyard', 'CFBundleName' => 'Lanyard',
               'ITSAppUsesNonExemptEncryption' => false,
               'LSApplicationCategoryType' => 'public.app-category.utilities', 'CFBundleIconName' => 'AppIcon' }
  expected.each { |key, value| abort "error: App Store Info.plist #{key} is #{settings[key].inspect}." unless settings[key] == value }
  abort 'error: App Store build configures Sparkle.' if settings.keys.any? { |name| name.start_with?('SU') }
  abort 'error: App Store build bundles Sparkle.' if File.exist?("#{store}/Frameworks")
  abort 'error: App Store build is missing its privacy manifest.' unless File.file?("#{store}/Resources/PrivacyInfo.xcprivacy")
  entitlements, status = Open3.capture2e('codesign', '-d', '--entitlements', '-', '--xml', "#{fixture}/Lanyard.app")
  abort 'error: App Store build is not sandboxed.' unless status.success? && entitlements.include?('com.apple.security.app-sandbox')
  abort 'error: App Store installer package was not built.' unless File.file?("#{fixture}/Lanyard-0.1.0.pkg")
  puts 'Sandboxed App Store variant, branding, privacy manifest, and installer package verified.'
ensure
  FileUtils.remove_entry_secure(fixture) if File.directory?(fixture)
end
