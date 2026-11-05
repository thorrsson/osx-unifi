---
title: Troubleshooting
description: Fix connection, API key, certificate, Keychain and update problems in UniFi Desktop.
permalink: /troubleshooting/
---

# Troubleshooting

UniFi Desktop shows a specific message when something goes wrong, rather than an empty page. Find the message you're seeing below.

## Connecting

### The app can't reach the console

- Check that your Mac is on the same network as the console, or connected to it over VPN.
- Open the console address in a browser on this Mac. If it doesn't load there, the app can't reach it either.
- On macOS 15 and later, the app needs **Local Network** access. Open **System Settings › Privacy & Security › Local Network** and make sure **UniFi Desktop** is turned on.

### "Enter an HTTPS controller origin…"

Enter only the console's address, starting with `https://`, such as `https://192.168.1.1`. Leave out paths like `/network` or `/proxy/network`, and anything after the address. A port is allowed, for example `https://192.168.1.1:8443`.

### "The controller redirected the request…"

The address you entered sends the app somewhere else. The app never follows redirects, so your API key can't be sent to a different address. Use the console's direct address, such as its IP address.

### "The official Network integration v1 endpoint is unavailable…"

The address answered, but not with the UniFi Network API. Check that:

- The address is your UniFi console, not another device or a ui.com page.
- The UniFi Network application is installed and running on the console.
- UniFi Network is up to date. The local API is part of recent UniFi Network versions; see [supported versions]({{ '/getting-started/' | relative_url }}#supported-unifi-network-versions).

## API key

### "The controller rejected the API key or its permissions (401/403)…"

The console doesn't accept the API key. It may be mistyped, deleted, expired, or not allowed to make the change you tried.

1. On the console, go to **Settings › Control Plane › Integrations** and create a new API key.
2. In UniFi Desktop, choose **Account › Forget API Key…** if you're connected, or just paste the new key into **API key** on the sign-in window.
3. Click **Connect**.

If you can browse but every change is rejected with 401 or 403, the key doesn't have permission to make changes. Create one that does.

### macOS asks for a password, or Keychain error -25293

UniFi Desktop keeps your API key in your Mac's login Keychain. When macOS asks whether **UniFi Desktop** can use it, enter your **Mac login password**, not the UniFi API key, and click **Allow** or **Always Allow**. This can happen after the app is updated.

Error **-25293** means macOS couldn't authorize access to the saved key. It doesn't mean the console rejected your key.

1. Open **Keychain Access** and make sure the **login** keychain is unlocked.
2. Click **Connect** again and approve the prompt.

The app never deletes your saved key to recover from a Keychain error. If you'd rather start over, choose **Account › Forget API Key…** and connect with the key again.

## Certificates

### The certificate review appears when I connect

That's expected the first time. UniFi consoles use a self-signed certificate that macOS doesn't trust, so the app asks you to check it before sending your API key. See [Review the console's certificate]({{ '/getting-started/' | relative_url }}#4-review-the-consoles-certificate).

To stop seeing it at all, install a certificate on your console that macOS already trusts, such as one from Let's Encrypt or your own certificate authority, with a name matching the address you connect to.

### The console's certificate changed

If the console presents a different certificate from the one you trusted, the app refuses to connect and shows both fingerprints. This is normal after the console regenerates its certificate, for example after a reset, restore or replacement, or after you install a new certificate.

1. Check the new fingerprint with the `openssl` command shown in the sheet, on a network you trust.
2. If it matches, click **Trust New Certificate**.

If you didn't expect a change, don't trust it. Something else may be answering at that address.

You can also choose **Account › Forget Trusted Certificate…** to remove the remembered certificate and review it fresh on the next connection.

## Pages and changes

### A version warning banner

> UniFi Network *version* has not been checked against this app…

Your console runs a UniFi Network version this app hasn't been checked against, typically a newer release. The app still works. Your console validates every change, so check the results of changes carefully. Look for a [newer UniFi Desktop release](https://github.com/thorrsson/osx-unifi/releases).

If the banner says the version is **unrecognized**, version-specific options, such as firewall flow reporting, are turned off.

### A page says "Couldn't load…"

Each page loads separately, so one failing page doesn't affect the others. Click **Try Again** on that page, or **Refresh** (<kbd>⌘</kbd><kbd>R</kbd>) to reload everything. The message explains the cause, for example a permission problem or a response the app didn't recognize.

### "The controller rejected the request…"

The console refused the change, and nothing was changed. The console's own explanation follows, for example a duplicate name or a VLAN ID that's already used. Fix the value and try again.

### A change is unconfirmed

The connection failed, or the console's reply didn't match what was sent, so the app can't tell whether the change was applied. It doesn't retry automatically. Click **Refresh**, check the item, and only then try again.

### A setting I need isn't in the app

UniFi Desktop only uses the official UniFi Network API, which doesn't cover everything. Click **Open in Web UI** in the toolbar to open the same page in your console's web UI. See [What the app doesn't manage]({{ '/managing/' | relative_url }}#what-the-app-doesnt-manage).

## Updates

### "Updates are unavailable in this build"

You're running a copy of the app that wasn't built as a signed release, for example one built from source. [Download the latest release](https://github.com/thorrsson/osx-unifi/releases/latest) to get automatic updates.

### Checking for updates fails

Make sure your Mac can reach GitHub, where updates are published, then choose **UniFi Desktop › Check for Updates…** again.

## Still stuck?

[Open an issue on GitHub](https://github.com/thorrsson/osx-unifi/issues) with:

- The UniFi Desktop version, from **UniFi Desktop › About UniFi Desktop**.
- Your UniFi Network version, shown at the bottom of the sidebar.
- The exact message you see.

Never include your API key, and remove any addresses or names you'd rather keep private.
