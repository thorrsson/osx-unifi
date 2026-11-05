require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'base64'
require 'json'
require 'openssl'
require 'rexml/document'

class ReleaseScriptsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SETTINGS = %w[
    MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY MACOS_TEAM_ID
    NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID NOTARY_API_KEY_P8
    SPARKLE_PRIVATE_KEY UNIFI_SPARKLE_FEED_URL HOMEBREW_TAP_TOKEN
  ].freeze

  def run_script(script, *args, env: {})
    Open3.capture3(env, 'bash', File.join(ROOT, 'Scripts', script), *args, chdir: ROOT)
  end

  def dotenv(directory, omitted: nil, extra: '', literal: nil)
    path = File.join(directory, 'release.env')
    lines = SETTINGS.reject { |key| key == omitted }.map do |key|
      value = key == 'MACOS_CERTIFICATE_PASSWORD' && literal ? literal : "fake-#{key}"
      "export #{key}='#{value}'"
    end
    File.write(path, "# synthetic test values only\n\n#{lines.join("\n")}\n#{extra}")
    File.chmod(0o600, path)
    path
  end

  def test_secret_dry_run_does_not_execute_values_or_expose_them
    Dir.mktmpdir('unifi-release-test') do |dir|
      marker = File.join(dir, 'must-not-exist')
      literal = "$(touch #{marker})"
      path = dotenv(dir, literal: literal)
      out, err, status = run_script('setup-release-secrets.sh', '-f', path, '-R', 'owner/repo', '--dry-run')
      assert status.success?, err
      assert_equal SETTINGS.length, out.lines.length
      assert_includes out, 'Would set variable UNIFI_SPARKLE_FEED_URL'
      refute_includes out + err, literal
      refute_includes out + err, 'fake-'
      refute File.exist?(marker)
    end
  end

  def test_secret_parser_rejects_unknown_duplicate_missing_and_unmatched_quotes
    Dir.mktmpdir('unifi-release-test') do |dir|
      cases = [
        { extra: "UNKNOWN_SETTING=value\n" },
        { extra: "MACOS_TEAM_ID=duplicate\n" },
        { omitted: 'SPARKLE_PRIVATE_KEY' },
        { extra: "not-an-assignment\n" }
      ]
      cases.each do |options|
        path = dotenv(dir, **options)
        out, err, status = run_script('setup-release-secrets.sh', '-f', path, '-R', 'owner/repo', '-n')
        refute status.success?
        assert_empty out
        assert_includes err, 'error:'
        refute_includes err, 'fake-'
      end
      path = dotenv(dir)
      File.write(path, "MACOS_CERTIFICATE_P12=\"unterminated\n")
      _, err, status = run_script('setup-release-secrets.sh', '-f', path, '-R', 'owner/repo', '-n')
      refute status.success?
      assert_includes err, 'Unmatched quote'
    end
  end

  def test_secret_upload_uses_stdin_and_existing_release_environment
    Dir.mktmpdir('unifi-release-test') do |dir|
      path = dotenv(dir)
      log = File.join(dir, 'gh.log')
      fake_gh = File.join(dir, 'gh')
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require 'json'
        File.open(ENV.fetch('TEST_GH_LOG'), 'a') do |file|
          file.puts({ args: ARGV, stdin: ARGV.first == 'api' ? '' : STDIN.read }.to_json)
        end
      RUBY
      File.chmod(0o700, fake_gh)
      _, err, status = run_script('setup-release-secrets.sh', '-f', path, '-R', 'owner/repo',
                                 env: { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'TEST_GH_LOG' => log })
      assert status.success?, err
      require 'json'
      calls = File.readlines(log).map { |line| JSON.parse(line) }
      assert_equal SETTINGS.length + 1, calls.length
      assert_equal ['api', '--method', 'GET', 'repos/owner/repo/environments/release', '--silent'], calls.first['args']
      calls.drop(1).each do |call|
        assert_includes call['args'], 'release'
        refute call['args'].any? { |arg| arg.start_with?('fake-') }
        assert call['stdin'].start_with?('fake-')
      end
    end
  end

  def test_update_plist_configuration_validates_feed_and_public_key
    Dir.mktmpdir('unifi-release-test') do |dir|
      plist = File.join(dir, 'Info.plist')
      key = Base64.strict_encode64("\x01" * 32)
      FileUtils.cp(File.join(ROOT, 'Resources/Info.plist'), plist)
      out, err, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/configure-updates.rb'),
                                       plist, 'https://example.com/appcast.xml', key)
      assert status.success?, out + err
      value, status = Open3.capture2('/usr/libexec/PlistBuddy', '-c', 'Print :SUPublicEDKey', plist)
      assert status.success?
      assert_equal key, value.strip
      %w[http://example.com https://user:pass@example.com https://example.com/#fragment].each do |feed|
        _, _, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/configure-updates.rb'), plist, feed, key)
        refute status.success?
      end
    end
  end

  def test_committed_sparkle_public_key_is_valid
    key = File.read(File.join(ROOT, 'Resources/sparkle_ed_public_key.txt')).strip
    assert_equal 32, Base64.strict_decode64(key).bytesize
  end

  def test_release_refuses_explicitly_disabled_updates
    _, err, status = run_script('release.sh', '1.0.0', env: {
      'UNIFI_SIGNING_IDENTITY' => 'synthetic-test-identity',
      'UNIFI_NOTARY_PROFILE' => 'synthetic-test-profile',
      'SPARKLE_PRIVATE_KEY' => 'synthetic-test-key',
      'UNIFI_SPARKLE_PUBLIC_ED_KEY' => ''
    })
    refute status.success?
    assert_includes err, 'A Sparkle public key is required for releases.'
  end

  def test_sparkle_keypair_check_rejects_a_mismatched_public_key
    key = OpenSSL::PKey.generate_key('ED25519')
    private_key = Base64.strict_encode64(key.private_to_der.byteslice(-32, 32))
    public_key = Base64.strict_encode64(key.public_to_der.byteslice(-32, 32))
    other = Base64.strict_encode64(OpenSSL::PKey.generate_key('ED25519').public_to_der.byteslice(-32, 32))
    script = File.join(ROOT, 'Scripts/check-sparkle-keypair.rb')
    _, err, status = Open3.capture3({ 'SPARKLE_PRIVATE_KEY' => private_key }, 'ruby', script, public_key)
    assert status.success?, err
    _, err, status = Open3.capture3({ 'SPARKLE_PRIVATE_KEY' => private_key }, 'ruby', script, other)
    refute status.success?
    assert_includes err, 'does not match'
    refute_includes err, private_key
    _, err, status = Open3.capture3({ 'SPARKLE_PRIVATE_KEY' => 'not-a-key' }, 'ruby', script, public_key)
    refute status.success?
    assert_includes err, 'Sparkle key check failed'
  end

  def test_appcast_without_signature_explains_key_mismatch
    Dir.mktmpdir('unifi-release-test') do |dir|
      archive = File.join(dir, 'UniFiDesktop-1.0.0.dmg')
      File.binwrite(archive, 'synthetic archive')
      feed = File.join(dir, 'appcast.xml')
      File.write(feed, <<~XML)
        <rss><channel><item><enclosure url="https://example.com/UniFiDesktop-1.0.0.dmg"
        length="#{File.size(archive)}"/></item></channel></rss>
      XML
      key = Base64.strict_encode64(OpenSSL::PKey.generate_key('ED25519').public_to_der.byteslice(-32, 32))
      _, err, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/verify-appcast.rb'), feed, archive, key)
      refute status.success?
      assert_includes err, 'no sparkle:edSignature'
    end
  end

  def test_appcast_checks_signature_size_and_embedded_public_key
    Dir.mktmpdir('unifi-release-test') do |dir|
      archive = File.join(dir, 'UniFiDesktop-1.0.0.dmg')
      File.binwrite(archive, 'synthetic archive')
      key = OpenSSL::PKey.generate_key('ED25519')
      public_key = Base64.strict_encode64(key.public_to_der.byteslice(-32, 32))
      signature = Base64.strict_encode64(key.sign(nil, File.binread(archive)))
      feed = File.join(dir, 'appcast.xml')
      File.write(feed, <<~XML)
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><enclosure url="https://example.com/UniFiDesktop-1.0.0.dmg"
          length="#{File.size(archive)}" sparkle:edSignature="#{signature}"/></item></channel>
        </rss>
      XML
      _, err, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/verify-appcast.rb'), feed, archive, public_key)
      assert status.success?, err
      wrong_key = Base64.strict_encode64(OpenSSL::PKey.generate_key('ED25519').public_to_der.byteslice(-32, 32))
      _, _, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/verify-appcast.rb'), feed, archive, wrong_key)
      refute status.success?
      File.binwrite(archive, 'tampered archive!')
      _, _, status = Open3.capture3('ruby', File.join(ROOT, 'Scripts/verify-appcast.rb'), feed, archive, public_key)
      refute status.success?
    end
  end

  def test_release_refuses_missing_credentials_instead_of_local_fallback
    clean_env = %w[UNIFI_SIGNING_IDENTITY UNIFI_NOTARY_PROFILE NOTARY_API_KEY_ID
                   NOTARY_API_ISSUER_ID NOTARY_API_KEY_P8].to_h { |name| [name, nil] }
    _, err, status = run_script('release.sh', '1.0.0', env: clean_env)
    refute status.success?
    assert_includes err, 'releases cannot use ad-hoc signing'
  end

  def test_icon_document_only_references_layers_that_exist
    icon = File.join(ROOT, 'Resources', 'AppIcon.icon')
    document = JSON.parse(File.read(File.join(icon, 'icon.json')))
    layers = document.fetch('groups').flat_map { |group| group.fetch('layers') }
    refute_empty layers
    layers.each do |layer|
      asset = File.join(icon, 'Assets', layer.fetch('image-name'))
      assert File.file?(asset), "icon layer is missing its asset: #{asset}"
    end
  end

  def render_cask(*args)
    Open3.capture3('ruby', File.join(ROOT, 'Scripts/render-cask.rb'), *args, chdir: ROOT)
  end

  def test_cask_points_at_the_released_dmg_and_installed_app
    sha = 'a' * 64
    out, err, status = render_cask('v1.2.3', sha)
    assert status.success?, err
    assert_includes out, 'cask "unifi-desktop" do'
    assert_includes out, 'version "1.2.3"'
    assert_includes out, %(sha256 "#{sha}")
    url = out[/^\s*url "([^"]+)"/, 1].gsub('#{version}', '1.2.3')
    assert_equal 'https://github.com/thorrsson/osx-unifi/releases/download/v1.2.3/UniFiDesktop-1.2.3.dmg', url
    assert_includes File.read(File.join(ROOT, 'Scripts/make-dmg.sh')), 'UniFiDesktop-$version.dmg'
    plist = File.read(File.join(ROOT, 'Resources/Info.plist'))
    bundle_name = plist[%r{<key>CFBundleName</key><string>([^<]+)</string>}, 1]
    bundle_id = plist[%r{<key>CFBundleIdentifier</key><string>([^<]+)</string>}, 1]
    assert_includes out, %(app "#{bundle_name}.app")
    assert_includes out, "~/Library/Preferences/#{bundle_id}.plist"
    assert_equal '14.0', plist[%r{<key>LSMinimumSystemVersion</key><string>([^<]+)</string>}, 1]
    assert_includes out, 'depends_on macos: :sonoma'
    assert_includes out, 'auto_updates true'
    feed = File.read(File.join(ROOT, '.env.example'))[/^UNIFI_SPARKLE_FEED_URL=(.+)$/, 1]
    assert_includes out, %(url "#{feed}")
    _, _, syntax = Open3.capture3('ruby', '-c', stdin_data: out)
    assert syntax.success?
  end

  def test_cask_writes_output_file_and_rejects_invalid_input
    Dir.mktmpdir('unifi-release-test') do |dir|
      path = File.join(dir, 'unifi-desktop.rb')
      _, err, status = render_cask('1.0.0', 'b' * 64, path)
      assert status.success?, err
      assert_includes File.read(path), 'version "1.0.0"'
    end
    [['1.0', 'a' * 64], ['1.0.0', 'A' * 64], ['1.0.0', 'a' * 63], ['1.0.0"; system("x")', 'a' * 64], ['1.0.0']].each do |args|
      out, err, status = render_cask(*args)
      refute status.success?, args.inspect
      assert_empty out
      assert_includes err, 'error:'
    end
  end

  def test_sparkle_artifact_and_tool_pins_match
    manifest = File.read(File.join(ROOT, 'Package.swift'))
    helper = File.read(File.join(ROOT, 'Scripts/lib/sparkle.sh'))
    assert_includes manifest, helper[/SPARKLE_VERSION="([^"]+)"/, 1]
    assert_includes manifest, helper[/SPARKLE_ZIP_SHA256="([^"]+)"/, 1]
  end
end
