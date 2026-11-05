require 'base64'
require 'openssl'

# Fails fast when SPARKLE_PRIVATE_KEY cannot sign updates for the public key the app embeds.
abort 'error: expected the embedded Sparkle public key' unless ARGV.length == 1
begin
  expected = Base64.strict_decode64(ARGV[0].strip)
  raise 'Sparkle public key must be 32 bytes' unless expected.bytesize == 32
  raw = Base64.decode64(ENV.fetch('SPARKLE_PRIVATE_KEY', '').strip)
  derived = case raw.bytesize
            when 32
              # Current Sparkle exports are the raw Ed25519 seed; wrap it as RFC 8410 PKCS#8.
              der = ['302e020100300506032b657004220420'].pack('H*') + raw
              OpenSSL::PKey.read(der).public_to_der.byteslice(-32, 32)
            when 96
              # Legacy exports append the public key to the 64-byte expanded secret key.
              raw.byteslice(64, 32)
            else
              raise 'SPARKLE_PRIVATE_KEY is not a base64 Sparkle Ed25519 private key'
            end
  unless derived == expected
    raise 'SPARKLE_PRIVATE_KEY does not match the Sparkle public key embedded in the app ' \
          '(Resources/sparkle_ed_public_key.txt or UNIFI_SPARKLE_PUBLIC_ED_KEY)'
  end
rescue StandardError => error
  abort "error: Sparkle key check failed: #{error.message}"
end
