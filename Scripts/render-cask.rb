#!/usr/bin/env ruby
# Renders the Homebrew cask published to thorrsson/homebrew-tap as Casks/unifi-desktop.rb.
# Usage: ruby Scripts/render-cask.rb VERSION SHA256 [OUTPUT]
# Writes to stdout when OUTPUT is omitted.

def fail_with(message)
  warn "error: #{message}"
  exit 1
end

version, sha256, output = ARGV
fail_with 'Usage: ruby Scripts/render-cask.rb VERSION SHA256 [OUTPUT]' unless version && sha256 && ARGV.length <= 3
version = version.delete_prefix('v')
fail_with 'Version must be three numeric components, for example 0.1.0.' unless version.match?(/\A\d+\.\d+\.\d+\z/)
fail_with 'SHA-256 must be 64 lowercase hexadecimal characters.' unless sha256.match?(/\A[0-9a-f]{64}\z/)

cask = <<~RUBY
  cask "unifi-desktop" do
    version "#{version}"
    sha256 "#{sha256}"

    url "https://github.com/thorrsson/osx-unifi/releases/download/v\#{version}/UniFiDesktop-\#{version}.dmg"
    name "UniFi Desktop"
    desc "Manage a UniFi network through the controller's local Network API"
    homepage "https://thorrsson.github.io/osx-unifi/"

    livecheck do
      url "https://raw.githubusercontent.com/thorrsson/osx-unifi/main/appcast.xml"
      strategy :sparkle, &:short_version
    end

    auto_updates true
    depends_on macos: :sonoma

    app "UniFi Desktop.app"

    zap trash: [
      "~/Library/Caches/com.thorrsson.osx-unifi",
      "~/Library/HTTPStorages/com.thorrsson.osx-unifi",
      "~/Library/Preferences/com.thorrsson.osx-unifi.plist",
      "~/Library/Saved Application State/com.thorrsson.osx-unifi.savedState",
    ]
  end
RUBY

if output
  File.write(output, cask)
else
  print cask
end
