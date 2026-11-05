# UniFi Desktop

A native SwiftUI macOS application for managing a UniFi network directly through
the controller's official local Network API. Credentials stay in macOS Keychain;
network inventory stays in memory. No cloud account login or undocumented legacy
API is used.

**User guide:** <https://thorrsson.github.io/osx-unifi/>

## Features

A dark, console-style interface with a sidebar for each area of the selected site.
Every section loads independently: a section that fails shows its own error and a
Retry action instead of an empty list, while the rest of the site stays usable.

- **Dashboard**: gateway health, WAN interfaces, and device, client, network and WiFi counts.
- **Devices**: adopted devices with details and latest statistics. Restart a device,
  power-cycle a PoE port, adopt a pending device, or remove (unadopt) a device.
- **Clients**: connected clients. Authorize a guest with the site defaults or custom
  time, data and rate limits, or revoke guest access.
- **Networks**: create, edit, enable/disable and delete networks (name, VLAN, gateway
  subnet, DHCP server or relay, DNS overrides, isolation, internet access, zone), with
  a check of what still references a network before deleting it.
- **WiFi**: create, edit, enable/disable and delete WiFi broadcasts (SSID, network,
  bands, WPA2/WPA3/open security and passphrase, hidden SSID, client isolation).
  Enterprise and other unrecognized security modes are preserved untouched.
- **Firewall**: zone-based policies with create, edit, enable/disable, logging, delete,
  and ordering (move up/down, evaluate before or after built-in policies); firewall
  zones with create, rename, network membership and delete.
- **DNS**: local DNS records (A, AAAA, CNAME, TXT, MX, SRV) and forward domains.
- **Hotspot**: create vouchers in bulk with duration, guest and usage limits, copy
  codes, delete selected vouchers, or delete all expired vouchers.
- Open the matching page of the controller's web UI for anything the app doesn't edit.
- Install signed updates through Sparkle, with Check for Updates in the app menu
  and update preferences in Settings.

The app manages your network, but it does not claim configuration parity with UniFi.
It edits what the official API documents. Editors start from the controller's own
current settings and change only the fields they show, so settings the app does not
display (for example firewall traffic filters, schedules, or advanced WiFi options)
are sent back unchanged. Items that only the web UI can edit say so and link to it.
Built-in (system-defined) items are read-only. Destructive changes ask for
confirmation. No automatic changes are made. The only background polling is a read of
the gateway's statistics every 3 seconds while the Dashboard is open.

## Install

Download the latest notarized DMG from
[Releases](https://github.com/thorrsson/osx-unifi/releases/latest), or use Homebrew:

```sh
brew install --cask thorrsson/tap/unifi-desktop
```

The cask lives in [thorrsson/homebrew-tap](https://github.com/thorrsson/homebrew-tap).
Homebrew versions that require trusting third-party taps need `brew trust thorrsson/tap`
once. The cask declares `auto_updates`, so Sparkle, not `brew upgrade`, keeps it current.

## Build and run

Running the app requires macOS 14+. Development needs Xcode (Swift 5.9+) and Ruby 3.2+
with OpenSSL supporting Ed25519 for release-tool tests and signed update verification.
CI selects Ruby 3.3. Building the app bundle with `Scripts/build-app.sh` needs the full
Xcode 26 on macOS 26, not just the Command Line Tools, because the app icon is an Icon
Composer document compiled by `actool` (see [App icon](#app-icon)).
Sparkle 2.9.6 is a checksum-pinned binary SwiftPM dependency; the matching release
tools are also checksum-verified before execution.

```sh
bash Scripts/test.sh
bash Scripts/build-app.sh 0.1.0
open "dist/UniFi Desktop.app"
```

Set `UNIFI_UNIVERSAL=1` to build both Apple Silicon and Intel slices.
`bash Scripts/make-dmg.sh 0.1.0` produces a drag-to-Applications disk image.
Local builds default to ad-hoc signing and clearly identify themselves as
**not distributable**. The app includes its Local Network privacy description
and embedded Sparkle helpers. Running a bare `swift run` executable is not the
normal app launch path and does not provide configured software updates.

For repeated local testing, use the same installed Developer ID identity so macOS can
recognize the app across rebuilds and retain its Keychain access:

```sh
UNIFI_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash Scripts/build-app.sh 0.1.0
```

Changing from ad-hoc to Developer ID signing may require approving access to existing
Keychain items once. This signs the local app; it does not notarize or publish a release.

### Documentation site

`docs/` is a Jekyll site published to GitHub Pages by `.github/workflows/pages.yml`
(pull requests build it; pushes to `main` deploy it). The repository's Pages source
must be **GitHub Actions**. Pages use the `default` layout, `assets/site.css`, and
`assets/downloads.js`, which links download buttons to the latest release's
`UniFiDesktop-*.dmg` and falls back to the releases page.

Screenshots in `docs/assets/screenshots/` and the tour video
`docs/assets/unifi-desktop-tour.mp4` are generated, not hand-made:

```sh
bash Scripts/build-app.sh 0.1.0
ruby Scripts/docs/capture.rb            # add --no-video for screenshots only
```

`capture.rb` starts `Scripts/docs/demo_controller.rb`, a local HTTPS controller serving
fictional "Harbor House" data from the documented API shapes, and launches an ad-hoc
signed copy of `dist/UniFi Desktop.app` (or `--app PATH`) under a separate bundle
identifier, so your real settings and Keychain items are untouched. `Scripts/docs/DocsDriver.swift` then drives the app through
the Accessibility API while `screencapture` records, and `Scripts/docs/VideoEncoder.swift`
encodes the MP4. It needs Accessibility and Screen Recording permission for the terminal,
takes over the mouse for about two minutes, and never contacts a real controller.

### App icon

`Resources/AppIcon.icon` is an Icon Composer document: a cyan-to-blue gradient fill with
two SVG layers (`nodes` and `links`) forming a generic hub-and-spoke network map. It
deliberately does not reuse Ubiquiti's UniFi logo. `Scripts/build-app.sh` compiles it with
`actool` into `Assets.car` (the layered light/dark/tinted icon macOS 26 renders) plus a flat
`AppIcon.icns` fallback, and merges the `CFBundleIconFile`/`CFBundleIconName` keys that
`actool` emits into the bundle's `Info.plist`. Open the document in Icon Composer to adjust
it, or edit the SVGs under `Resources/AppIcon.icon/Assets/` directly.

## Connect and manage

1. On the LAN or VPN, create a **local Network API key** in UniFi Network under
   Settings > Control Plane > Integrations. Use the least permissions needed; management
   actions require appropriate write access. This is not a ui.com cloud API key.
2. Enter the direct HTTPS origin, such as `https://unifi.example.net` or
   `https://192.168.1.1`, without `/network` or `/proxy/...`. Paste the key and Connect.
3. Choose a site. Use each page's toolbar, context menus (Control-click a row) or
   double-click to create, edit and delete. Refresh (Command-R) reloads the Network
   version, sites and the selected site.

Keys are saved in this Mac's non-synchronizing Keychain after version/sites load.
Only the controller address is saved in UserDefaults. Leave the key field blank
to use the saved key; the app never connects automatically. Disconnect clears
in-memory inventory and credentials, retaining the saved key. Forget Saved Key
removes the key for the entered origin.

If Keychain reports **-25293**, macOS could not authorize access to a saved item; this is
not the controller rejecting the API key. Unlock the login keychain in Keychain Access
and retry. A macOS Keychain password prompt needs your Mac login/keychain password,
not the UniFi API key. Approve access only for the app you just built and launched.
Ad-hoc signatures change when the executable changes and can trigger new access
requests; consistent Developer ID signing avoids that on subsequent rebuilds.
The app never deletes saved credentials or bypasses Keychain authorization to recover.

### Controller certificates

A UniFi console normally presents a certificate that macOS does not trust, such as
its built-in self-signed certificate. The app never disables TLS verification.
Instead, when macOS does not trust the certificate, the handshake is stopped
**before any request or API key is sent** and a review sheet shows the certificate
name and its SHA-256 fingerprint. Choosing **Trust and Connect** pins that exact
leaf certificate for that controller origin in the Keychain and connects.

- Verify the fingerprint independently if you can. The sheet shows a ready-made
  command, equivalent to
  `echo | openssl s_client -connect 192.168.1.1:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256`.
- If the controller later presents a different certificate (for example after it
  regenerates one, or a restore), the app refuses to connect and asks again, naming
  both fingerprints. Nothing is replaced until you review it.
- **Forget Trusted Certificate** removes the pin for the entered origin and
  disconnects. A pin the app cannot read is an explicit error, never silently
  ignored or treated as trusted.
- A certificate macOS already trusts (for example a Let's Encrypt or internal-CA
  certificate installed in your keychain, with a matching hostname) connects
  without any prompt, and is the lowest-maintenance option.

Allow Local Network access when macOS asks. Keys are never sent over HTTP or
followed through redirects.

Changes are sent once and never retried automatically. Every change ends in one of
three explicit outcomes:

- **Accepted**: the controller confirmed it (for updates, by echoing the same item).
  Only the affected sections are reloaded; a reload failure shows on that section.
- **Rejected**: the controller refused it (HTTP 400/404/409/412/422), its documented
  error message is shown, and nothing was changed.
- **Unconfirmed**: the connection failed or the reply didn't match, so the outcome
  may be unknown. Refresh and check before trying again.

A device restart or a network change can interrupt the connection to the
controller itself; an HTTP acknowledgement does not mean a restart has completed.

## Official API and compatibility

`UniFiCore.NetworkAPI` isolates UI/application state from `IntegrationV1API`.
The adapter uses only the documented local `/proxy/network/integration/v1` endpoints,
authenticated with `X-API-Key`:

```text
GET                 /info, /sites, /pending-devices
GET                 /sites/{siteId}/devices, /clients, /wans
GET                 /sites/{siteId}/devices/{deviceId}, …/statistics/latest
POST                /sites/{siteId}/devices                                 adopt
DELETE              /sites/{siteId}/devices/{deviceId}                      remove
POST                /sites/{siteId}/devices/{deviceId}/actions              RESTART
POST                /sites/{siteId}/devices/{deviceId}/interfaces/ports/{n}/actions  POWER_CYCLE
POST                /sites/{siteId}/clients/{clientId}/actions              guest authorize/revoke
GET POST            /sites/{siteId}/networks | wifi/broadcasts | firewall/zones | firewall/policies | dns/policies
GET PUT DELETE      /sites/{siteId}/{resource}/{id}
GET                 /sites/{siteId}/networks/{id}/references
PATCH               /sites/{siteId}/firewall/policies/{id}                  logging, flow reporting
GET PUT             /sites/{siteId}/firewall/policies/ordering?sourceFirewallZoneId=&destinationFirewallZoneId=
GET POST DELETE     /sites/{siteId}/hotspot/vouchers                        DELETE uses filter=expired.eq(true)
DELETE              /sites/{siteId}/hotspot/vouchers/{id}
```

### Supported Network versions

Request and response shapes were checked against the official OpenAPI documents for
**Network 10.3.58 and 10.6.106** (stable) and **11.0.97**, published ahead of the
stable 11 release so the app is ready for it. See the
[official documentation and version selector](https://developer.ui.com/network/).

The installed version comes from `/info` and drives the documented differences:

| Version | Behaviour |
|---|---|
| 10.3 – 10.6.x | Verified. |
| 10.6 and later | New WiFi broadcasts include the `channel2gLockedTo6` and `dtimPeriod2gLockedTo3` fields that 10.6 made required. |
| 11.0.x | Verified against the pre-release documentation. Firewall policies gain **flow reporting**: a context-menu action, an editor toggle, and a default of on for new policies. It is never sent to older versions. |
| Anything else | Still usable, but a banner says the version hasn't been checked. The controller validates every change, and an unrecognized version string disables version-specific settings. |

Version 11 behaviour is based on the published documentation and has not yet been
exercised against a controller running 11.0.

Lists use `offset`/`limit` pagination, not cloud Site Manager token pagination.
All pages must succeed. Malformed envelopes, duplicate identities, incomplete pages,
schema mismatches, authentication/API errors, TLS failures and unreachable hosts are
surfaced explicitly; a genuinely empty list is shown as empty only when the controller
confirmed it. A 404 from a missing endpoint is reported as unsupported, separately
from a 404 for an item that no longer exists. Only the documented JSON `message` of
an error response is ever shown; other response bodies are not displayed. Unknown
device states, client types and resource fields remain visible or are preserved.

## Signing, releases, and Sparkle

The release design follows the user's existing apps:
[kcb-swift](https://github.com/thorrsson/kcb-swift) for SwiftPM bundling and
Sparkle, [ingram-report-native](https://github.com/thorrsson/ingram-report-native)
for literal dotenv secret provisioning and app-specific update keys, and
[tls-reader](https://github.com/thorrsson/tls-reader) for fail-closed signing and
publishing only after artifacts are verified.

Before the first release:

1. Create a GitHub **release** environment with required reviewers and deployment
   restrictions for `v*` tags. The setup script never creates or weakens protection.
   The workflow also requires the tagged commit to be on `main`.
2. This app's Sparkle public key is committed in `Resources/sparkle_ed_public_key.txt`.
   The matching private key is stored in the maintainer's Keychain account
   `com.thorrsson.osx-unifi.sparkle`, not another app's account. Back it up securely
   with `bash Scripts/sparkle-keys.sh export .sparkle/private-key.txt`.
   Never regenerate a key already shipped to users.
3. Copy `.env.example` to `.env`, set owner-only permissions (`chmod 600 .env`),
   and populate the certificate/password/identity/team, notary API key trio,
   Sparkle private key, and `HOMEBREW_TAP_TOKEN` (a fine-grained token limited to
   `thorrsson/homebrew-tap` with Contents read and write). Encode `.p12` and `.p8` files as single-line base64.
   The Sparkle private key uses Sparkle's exported text unchanged. The public key is
   not a secret: releases embed the committed key, and `Scripts/release.sh` fails
   before building if `SPARKLE_PRIVATE_KEY` does not derive that key.
4. Validate and then upload names/values:

```sh
bash Scripts/setup-release-secrets.sh --dry-run
bash Scripts/setup-release-secrets.sh
```

The helper is adapted from Ingram's script. It accepts literal one-line dotenv
assignments with optional `export` and matching quotes; it never sources the
file, expands values, or evaluates commands. Unknown/duplicate keys and missing
required values fail before upload. Secret values travel over stdin, never CLI
arguments; output contains names only. `UNIFI_SPARKLE_FEED_URL` is an environment
**variable**, the remaining settings are environment secrets. `-f` selects a
file and `-R owner/repo` explicitly selects another repository. No existing app's
credentials are read or copied automatically. No provisioning profile is needed:
this app uses neither sandbox/iCloud nor other profile-bound capabilities.

CI builds/tests and packages universal local-only artifacts without signing secrets.
A `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which imports the Developer
ID into a temporary keychain (added to the user keychain search list, since `codesign`
does not find identities through `--keychain` alone), verifies the identity can sign
before building, runs the test wrapper, signs the universal app and
Sparkle helpers with hardened runtime/timestamps, notarizes and staples the app,
packages/signs/notarizes/staples the DMG, and checks Gatekeeper acceptance. Signing
material is cleaned up even on failure. `CFBundleVersion` is the full-history
commit count; version overrides are validated before entering plist commands.

`Scripts/release.sh X.Y.Z` provides the same local pipeline using
`UNIFI_SIGNING_IDENTITY`, optional `UNIFI_SIGNING_KEYCHAIN`/`UNIFI_TEAM_ID`, and
either `UNIFI_NOTARY_PROFILE` or the three `NOTARY_API_KEY_*` environment values.
It requires a clean checkout, valid credentials, and matching Sparkle keys.
**Releases never fall back to unsigned, ad-hoc, or unnotarized output.**

The final stapled DMG gets a SHA-256 checksum and an Ed25519-signed Sparkle enclosure,
verified against the public key embedded in the app. Assets publish before the
signed appcast is committed to `main`. The default public feed is
`https://raw.githubusercontent.com/thorrsson/osx-unifi/main/appcast.xml`.
The workflow token must be allowed to commit that feed under the repository's
branch rules. For custom feed hosting, publish `dist/appcast.xml` at that URL;
private raw GitHub URLs are not usable by installed clients.
After the feed, the workflow renders `Casks/unifi-desktop.rb` with
`Scripts/render-cask.rb VERSION SHA256` from the published DMG checksum and pushes it
to [thorrsson/homebrew-tap](https://github.com/thorrsson/homebrew-tap) using
`HOMEBREW_TAP_TOKEN`; a missing token fails the release before building.
Local builds without a public key explicitly disable updates. No update private
key, real release credentials, or live controller API key belongs in Git.
Setting `UNIFI_SPARKLE_PUBLIC_ED_KEY=''` explicitly disables updates even when the
public key file exists; leaving it unset uses the committed public key. CI uses
the empty override for its local-only DMG. Release builds reject that override.

## Verification and release gates

`Scripts/test.sh` runs Ruby release-tool tests and Swift API/application-state
tests. Coverage includes parsing, requests/authentication, pagination, documented
create/update/patch/delete bodies and echo verification, policy ordering, version
gating, editor round-trips that preserve unshown settings, input validation bounds,
rejected versus unconfirmed outcomes and no retries, per-section failure handling,
Keychain failures through an injected store, the certificate trust policy and review
flow (including real TLS handshakes against a throwaway self-signed HTTPS fixture,
`Scripts/tests/tls_fixture.rb`), updater configuration, literal secret
parsing/stdin uploads, and signed appcast verification.

`ruby Scripts/test-packaging.rb` additionally builds a universal app and DMG
using throwaway Sparkle keys, confirms the bundle carries the compiled app icon
(`Assets.car`, `AppIcon.icns` and the `Info.plist` keys naming it), runs the real
appcast generator, verifies the
signature against the embedded public key, and removes its isolated fixtures.
It also rebuilds with an explicitly empty public key and confirms that updates
stay disabled despite the committed public key.
It never touches the release Keychain account or normal `dist/` output.

Local builds and universal DMG packaging can be checked without credentials.
Developer ID signing, Apple notarization/Gatekeeper acceptance, a real Sparkle
update installation, real Keychain prompts, your controller's actual certificate and
Local Network permission behavior, and live
management actions must be validated with the user's signing/update credentials
and UDM Pro before treating a release as production-validated. That includes the
API key's write permissions, every editor against your controller, and Network 11. This repository
does not manufacture credentials or claim those external gates passed.
