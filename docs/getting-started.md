---
title: Get started
description: Install UniFi Desktop, create a local Network API key on your UniFi console, and connect.
permalink: /getting-started/
---

# Get started

UniFi Desktop connects directly to your UniFi console, such as a Dream Machine Pro, over your local network. Setup takes a few minutes: install the app, create an API key on the console, then connect.

You need:

- A Mac running **macOS 14 Sonoma or later** (Apple silicon or Intel).
- A UniFi console running **UniFi Network** with the official local Network API. See [supported versions](#supported-unifi-network-versions).
- A network path from your Mac to the console: on the same LAN, or over a VPN.

## 1. Install the app

<p><a class="button" href="https://github.com/thorrsson/osx-unifi/releases/latest" data-download="mac" data-download-label="version">Download for Mac</a></p>

1. Open the downloaded `UniFiDesktop-X.Y.Z.dmg`.
2. Drag **UniFi Desktop** into **Applications**.
3. Open it from Applications or Launchpad.

Releases are signed with a Developer ID and notarized by Apple. The first time you open the app, macOS asks you to confirm opening an app downloaded from the internet. You can also browse [all releases and release notes](https://github.com/thorrsson/osx-unifi/releases).

### Or install with Homebrew

```sh
brew install --cask thorrsson/tap/unifi-desktop
```

If Homebrew refuses to load a cask from an untrusted tap, trust it once with `brew trust thorrsson/tap` and run the install again. The app keeps itself up to date (see [Software updates](#software-updates)), so `brew upgrade` normally has nothing to do. `brew uninstall --zap --cask unifi-desktop` also removes the app's preferences and caches; saved API keys and trusted certificates stay in your Keychain.

## 2. Create a local Network API key

The app uses an API key created on your console, not your ui.com account password.

1. In a browser, sign in to your console's UniFi Network application.
2. Go to **Settings › Control Plane › Integrations**.
3. Create an API key, give it a recognizable name such as "UniFi Desktop on my Mac", and copy it straight away. The console may not show it again.

<div class="callout warning" markdown="1">
Treat the key like a password: it can change your network. Use a **local** Network API key from the console itself. A Site Manager key from `unifi.ui.com` won't work. If you no longer need the app, delete the key on the same Integrations page.
</div>

## 3. Connect

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/connect.png' | relative_url }}" alt="UniFi Desktop sign-in window with Console address and API key fields" width="1280" height="820">
</figure>

1. In **Console address**, enter the console's HTTPS address, for example `https://192.168.1.1` or `https://unifi.example.net`. Enter just the address: no `/network` or `/proxy/...` path. Add a port only if your console uses one other than 443.
2. Paste the API key into **API key**.
3. Click **Connect**.

If macOS asks whether **UniFi Desktop** can find devices on your local network, click **Allow**. The app can't reach your console without Local Network access.

## 4. Review the console's certificate

A UniFi console normally uses a self-signed certificate that macOS doesn't trust. UniFi Desktop never turns off certificate checks. Instead, it stops the connection **before your API key is sent** and asks you to review the certificate.

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/certificate.png' | relative_url }}" alt="Trust this controller's certificate sheet showing the controller address, certificate name and SHA-256 fingerprint" width="1280" height="820">
  <figcaption>The review sheet shows the certificate's name and SHA-256 fingerprint.</figcaption>
</figure>

To make sure you're talking to your own console, compare the fingerprint with the one the console presents. In Terminal, on a trusted network, run the command shown in the sheet, replacing the address with your console's:

```sh
echo | openssl s_client -connect 192.168.1.1:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

If the fingerprints match, click **Trust and Connect**. The app remembers that exact certificate for this console and connects. If the console ever presents a different certificate, the app refuses to connect and asks you again. See [The console's certificate changed]({{ '/troubleshooting/' | relative_url }}#the-consoles-certificate-changed).

If your console uses a certificate macOS already trusts, such as one from Let's Encrypt or your own certificate authority, you won't see this step.

## 5. Choose a site and start managing

Once connected, the sidebar shows **Dashboard**, **UniFi Devices** and **Client Devices**, plus the **Settings** pages for **Networks**, **WiFi**, **Firewall**, **DNS** and **Hotspot**. If your console has more than one site, choose a site from the menu at the left of the toolbar.

See [Managing your network]({{ '/managing/' | relative_url }}) for what each page can do.

## Your API key and Keychain

After a successful connection, the app saves the API key in your Mac's login Keychain. It isn't synced to iCloud. Only the console address is saved in the app's preferences.

- **Next time**, enter or keep the console address, leave **API key** blank, and click **Connect** to use the saved key. The app never connects on its own.
- The **Account** menu (the person icon in the toolbar) has:
  - **Disconnect**: closes the connection and clears what was loaded. The saved key is kept.
  - **Forget API Key…**: removes the saved key for this console from Keychain and disconnects.
  - **Forget Trusted Certificate…**: removes the remembered certificate. You'll review it again on the next connection.

macOS may ask for your **Mac login password** to let UniFi Desktop use its Keychain item, for example after an update. That prompt wants your Mac password, not the UniFi API key.

## Software updates

UniFi Desktop updates itself with [Sparkle](https://sparkle-project.org). Every update is signed, and the app checks that signature before installing.

- Choose **UniFi Desktop › Check for Updates…** to check now.
- Open **UniFi Desktop › Settings…** (<kbd>⌘</kbd><kbd>,</kbd>) to choose whether the app checks automatically and downloads updates in the background.

You always approve installing an update and relaunching the app.

## Supported UniFi Network versions

The app reads your console's UniFi Network version when it connects. The version appears at the bottom of the sidebar.

| UniFi Network | Support |
|---|---|
| 10.3 – 10.6 | Supported and checked against the official API documentation. |
| 11.0 | Supported, based on the official documentation published ahead of its stable release. Adds flow reporting for firewall policies. |
| Other versions | The app still works, but shows a banner saying the version hasn't been checked. Your console validates every change. |

UniFi Desktop uses only the documented UniFi Network API, so it can't change every setting the web UI can. Use **Open in Web UI** for anything else. See [What the app doesn't manage]({{ '/managing/' | relative_url }}#what-the-app-doesnt-manage).
