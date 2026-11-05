require 'base64'
require 'openssl'
require 'rexml/document'

feed, archive, public_key = ARGV
abort 'error: expected feed, archive and public key' unless ARGV.length == 3
begin
  key = Base64.strict_decode64(public_key)
  raise 'Invalid public key size' unless key.bytesize == 32
  document = REXML::Document.new(File.read(feed))
  enclosure = REXML::XPath.match(document, '//enclosure').find do |entry|
    entry.attributes['url'].end_with?("/#{File.basename(archive)}")
  end
  raise 'No matching update enclosure' unless enclosure
  signature_attribute = enclosure.attributes['sparkle:edSignature']
  unless signature_attribute
    raise 'Enclosure has no sparkle:edSignature; generate_appcast did not sign it ' \
          '(SPARKLE_PRIVATE_KEY likely does not match the embedded public key)'
  end
  signature = Base64.strict_decode64(signature_attribute)
  raise 'Update length mismatch' unless enclosure.attributes['length'].to_i == File.size(archive)
  # RFC 8410 SubjectPublicKeyInfo wrapper for the raw Ed25519 public key.
  der = ["302a300506032b6570032100"].pack('H*') + key
  verifier = OpenSSL::PKey.read(der)
  raise 'Update signature does not match the embedded public key' unless verifier.verify(nil, signature, File.binread(archive))
rescue StandardError => error
  abort "error: appcast verification failed: #{error.message}"
end
