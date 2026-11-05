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
ensure
  FileUtils.remove_entry_secure(fixture) if File.directory?(fixture)
end
