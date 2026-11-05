#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the documentation screenshots and screencast for UniFi Desktop.
#
# The tour runs a separately identified copy of the built app against the fictional demo
# controller in demo_controller.rb, so published docs never show a real network and the
# capture never touches your own settings or Keychain items.
#
#   ruby Scripts/docs/capture.rb [--app PATH] [--no-video]
#
# The terminal needs Accessibility and Screen Recording access. The tour takes over the mouse
# and keyboard for about two minutes; leave the Mac alone until it finishes.

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"

ROOT = File.expand_path("../..", __dir__)
BUNDLE_ID = "com.thorrsson.osx-unifi.docs-capture"
SERVICES = %w[com.thorrsson.osx-unifi.local-network-api com.thorrsson.osx-unifi.trusted-certificate].freeze
DEMO_KEY = "docs-demo-key"
WORK = File.join(ROOT, ".build", "docs-capture")
SCREENSHOTS = File.join(ROOT, "docs", "assets", "screenshots")
VIDEO = File.join(ROOT, "docs", "assets", "unifi-desktop-tour.mp4")
MAX_SCREENSHOT_WIDTH = 1920
VIDEO_MAX_WIDTH = 1440
VIDEO_BITRATE = 1_000_000
VIDEO_FPS = 30
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

options = { app: File.join(ROOT, "dist", "UniFi Desktop.app"), video: true }
OptionParser.new do |parser|
  parser.banner = "usage: ruby Scripts/docs/capture.rb [--app PATH] [--no-video]"
  parser.on("--app PATH", "Built app to capture (default: dist/UniFi Desktop.app)") { |path| options[:app] = File.expand_path(path) }
  parser.on("--[no-]video", "Record the screencast (default: yes)") { |value| options[:video] = value }
end.parse!

def run!(*command, **options)
  system(*command, exception: true, **options)
end

def quietly(*command)
  system(*command, out: File::NULL, err: File::NULL)
end

def start_controller
  [8443, 0].each do |port|
    input, output, thread = Open3.popen2(RbConfig.ruby, File.join(__dir__, "demo_controller.rb"), "--port", port.to_s)
    line = output.gets
    return [input, thread, JSON.parse(line)] if line

    input.close
    thread.join
  end
  abort "The demo controller did not start."
end

def forget(origin)
  SERVICES.product([origin, "#{origin}/"]).each do |service, account|
    quietly("security", "delete-generic-password", "-s", service, "-a", account)
  end
  quietly("defaults", "delete", BUNDLE_ID)
  %w[Caches HTTPStorages WebKit].each { |folder| FileUtils.rm_rf(File.expand_path("~/Library/#{folder}/#{BUNDLE_ID}")) }
  FileUtils.rm_rf(File.expand_path("~/Library/Saved Application State/#{BUNDLE_ID}.savedState"))
end

def pixel_width(path)
  output, status = Open3.capture2("sips", "-g", "pixelWidth", path)
  abort "Could not read the size of #{path}." unless status.success?
  Integer(output[/pixelWidth: (\d+)/, 1])
end

abort "No app at #{options[:app]}. Build it first with: bash Scripts/build-app.sh" unless Dir.exist?(options[:app])

FileUtils.rm_rf(WORK)
raw_shots = File.join(WORK, "screenshots")
FileUtils.mkdir_p(raw_shots)
app = File.join(WORK, "UniFi Desktop.app")
driver = File.join(WORK, "docs-driver")
recording = File.join(WORK, "tour.mov")
encoder = File.join(WORK, "video-encoder")

puts "Preparing a separately identified copy of the app..."
run!("ditto", options[:app], app)
run!("/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier #{BUNDLE_ID}", File.join(app, "Contents", "Info.plist"))
run!("codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", app)
run!("xcrun", "swiftc", "-O", File.join(__dir__, "DocsDriver.swift"), "-o", driver)
run!("xcrun", "swiftc", "-O", File.join(__dir__, "VideoEncoder.swift"), "-o", encoder) if options[:video]

controller_input, controller, info = start_controller
origin = "https://127.0.0.1:#{info.fetch("port")}"
recorder = nil
succeeded = false

begin
  forget(origin)
  puts "Demo controller at #{origin}. The tour takes over the mouse and keyboard; please don't touch the Mac."
  sleep 3
  run!("open", "-n", "-F", app)
  frame, status = Open3.capture2(driver, "place", BUNDLE_ID)
  abort "Could not place the app window." unless status.success?

  if options[:video]
    recorder = Process.spawn("screencapture", "-v", "-C", "-k", "-x", "-R", frame.strip, recording)
    sleep 1.5
  end
  succeeded = system(driver, "tour", BUNDLE_ID, origin, DEMO_KEY, raw_shots)
  system(driver, "dump", BUNDLE_ID) unless succeeded
ensure
  if recorder
    Process.kill("INT", recorder)
    Process.wait(recorder)
  end
  quietly(driver, "quit", BUNDLE_ID)
  sleep 1
  controller_input.close
  controller.join
  forget(origin)
  quietly(LSREGISTER, "-u", app)
end

abort "The tour failed; screenshots and video were not updated." unless succeeded

FileUtils.mkdir_p(SCREENSHOTS)
Dir[File.join(raw_shots, "*.png")].sort.each do |source|
  target = File.join(SCREENSHOTS, File.basename(source))
  if pixel_width(source) > MAX_SCREENSHOT_WIDTH
    run!("sips", "--resampleWidth", MAX_SCREENSHOT_WIDTH.to_s, source, "--out", target, out: File::NULL)
  else
    FileUtils.cp(source, target)
  end
  puts "screenshot: #{target.delete_prefix("#{ROOT}/")}"
end

if options[:video]
  # A web-sized H.264 encode keeps the published tour around 5 MB while text stays legible.
  run!(encoder, recording, VIDEO, VIDEO_MAX_WIDTH.to_s, VIDEO_BITRATE.to_s, VIDEO_FPS.to_s)
  puts format("video: %<path>s (%<size>.1f MB)", path: VIDEO.delete_prefix("#{ROOT}/"), size: File.size(VIDEO) / 1_048_576.0)
end
