require 'base64'
require 'uri'
require 'open3'

plist, feed, key = ARGV
abort 'error: expected plist, feed and public key' unless ARGV.length == 3
if key.empty?
  warn 'warning: no Sparkle public key; software updates are explicitly disabled in this local build.'
  exit 0
end
begin
  raise ArgumentError unless Base64.strict_decode64(key).bytesize == 32
  url = URI.parse(feed)
  raise ArgumentError unless url.is_a?(URI::HTTPS) && url.host && !url.host.empty? && !url.userinfo && !url.fragment
rescue ArgumentError, URI::InvalidURIError
  abort 'error: Sparkle needs a 32-byte base64 Ed25519 public key and an HTTPS feed without credentials or fragments.'
end
{
  'SUFeedURL' => ['string', feed],
  'SUPublicEDKey' => ['string', key],
  'SUEnableAutomaticChecks' => ['bool', 'true'],
  'SUAutomaticallyUpdate' => ['bool', 'false'],
  'SUScheduledCheckInterval' => ['integer', '86400']
}.each do |name, (type, value)|
  # Pass values as arguments rather than interpolating them into a PlistBuddy command.
  output, status = Open3.capture2e('/usr/bin/plutil', '-insert', name, "-#{type}", value, plist)
  abort "error: configuring #{name}: #{output}" unless status.success?
end
