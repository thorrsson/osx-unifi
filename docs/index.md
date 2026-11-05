---
title: UniFi Desktop
description: A native Mac app for managing your UniFi network through the console's official local Network API.
wide: true
---

<section class="hero">
  <img class="hero-icon" src="{{ '/assets/app-icon.png' | relative_url }}" alt="" width="128" height="128">
  <div>
    <p class="eyebrow">Your UniFi network, native on your Mac</p>
    <h1>UniFi Desktop</h1>
    <p>Manage devices, clients, networks, WiFi, firewall policies, DNS and hotspot vouchers on your UniFi console from a fast, native macOS app. It talks directly to your console over your local network using the official UniFi Network API.</p>
    <div class="actions">
      <a class="button" href="https://github.com/thorrsson/osx-unifi/releases/latest" data-download="mac" data-download-label="version">Download for Mac</a>
      <a class="button secondary" href="{{ '/getting-started/' | relative_url }}">Get started</a>
    </div>
    <p class="meta">macOS 14 Sonoma or later · Apple silicon and Intel · <a href="https://github.com/thorrsson/osx-unifi/releases">All releases</a></p>
  </div>
</section>

<figure class="tour">
  <video controls muted playsinline preload="metadata" poster="{{ '/assets/screenshots/dashboard.png' | relative_url }}" aria-describedby="tour-caption">
    <source src="{{ '/assets/unifi-desktop-tour.mp4' | relative_url }}" type="video/mp4">
    <a href="{{ '/assets/unifi-desktop-tour.mp4' | relative_url }}">Download the UniFi Desktop tour video</a>.
  </video>
  <figcaption id="tour-caption">A short tour: trusting the console certificate, browsing devices and clients, editing a network, enabling a WiFi network, reviewing firewall policies and zones, and creating hotspot vouchers. The video has no sound. All names and addresses shown are fictional demo data.</figcaption>
</figure>

## Everything in one window

<div class="shot-grid">
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/dashboard.png' | relative_url }}" alt="Dashboard showing gateway health, WAN interfaces and counts of devices, clients, networks and WiFi" loading="lazy" width="1280" height="820">
    <figcaption><strong>Dashboard.</strong> Gateway health, WAN interfaces and a summary of the selected site.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/devices.png' | relative_url }}" alt="UniFi Devices table listing gateway, switches and access points with details for the selected device" loading="lazy" width="1280" height="820">
    <figcaption><strong>Devices.</strong> Details, ports and radios. Restart, power-cycle a PoE port, adopt or remove.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/clients.png' | relative_url }}" alt="Clients table listing wired, wireless and guest clients" loading="lazy" width="1280" height="820">
    <figcaption><strong>Clients.</strong> Who is connected, and guest authorization with optional limits.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/networks.png' | relative_url }}" alt="Networks table listing VLANs, subnets and DHCP modes" loading="lazy" width="1280" height="820">
    <figcaption><strong>Networks.</strong> Create and edit VLANs, subnets, DHCP, DNS and isolation.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/wifi.png' | relative_url }}" alt="WiFi table listing broadcasts with their networks, bands and security" loading="lazy" width="1280" height="820">
    <figcaption><strong>WiFi.</strong> SSIDs, bands, WPA2/WPA3 security, passphrases and isolation.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/firewall.png' | relative_url }}" alt="Firewall policies listed in evaluation order between zones" loading="lazy" width="1280" height="820">
    <figcaption><strong>Firewall.</strong> Zone-based policies with ordering, logging, and zone membership.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/dns.png' | relative_url }}" alt="DNS records table with A, CNAME and other record types" loading="lazy" width="1280" height="820">
    <figcaption><strong>DNS.</strong> Local A, AAAA, CNAME, TXT, MX and SRV records and forward domains.</figcaption>
  </figure>
  <figure>
    <img class="screenshot" src="{{ '/assets/screenshots/hotspot.png' | relative_url }}" alt="Hotspot vouchers table with codes, durations and expiry dates" loading="lazy" width="1280" height="820">
    <figcaption><strong>Hotspot.</strong> Create vouchers in bulk, copy codes, and clean up expired ones.</figcaption>
  </figure>
</div>

## Built for your console, not the cloud

<div class="feature-grid">
  <article class="feature">
    <h3>Direct and local</h3>
    <p>Connects straight to your UniFi console's official local Network API. No ui.com account, cloud relay or undocumented endpoints.</p>
  </article>
  <article class="feature">
    <h3>Safe with your settings</h3>
    <p>Editors change only the fields they show. Everything else is sent back exactly as the console had it, and destructive changes ask first.</p>
  </article>
  <article class="feature">
    <h3>Honest about failures</h3>
    <p>If something can't load or a change isn't confirmed, the app says so. It never shows an empty list in place of an error.</p>
  </article>
  <article class="feature">
    <h3>Your keys stay on your Mac</h3>
    <p>The API key is stored in your Mac's Keychain and never synced. Self-signed console certificates are reviewed and pinned before the key is sent.</p>
  </article>
  <article class="feature">
    <h3>Web UI when you need it</h3>
    <p>For settings the official API doesn't cover, Open in Web UI takes you to the matching page of your console.</p>
  </article>
  <article class="feature">
    <h3>Signed and up to date</h3>
    <p>Releases are Developer ID signed and notarized by Apple, and install updates through Sparkle.</p>
  </article>
</div>

## Next steps

- [Install the app and connect to your console]({{ '/getting-started/' | relative_url }})
- [Learn what you can manage and how]({{ '/managing/' | relative_url }})
- [Fix connection, certificate and Keychain problems]({{ '/troubleshooting/' | relative_url }})

UniFi Desktop is open source under the MIT License. See the [project on GitHub](https://github.com/thorrsson/osx-unifi) for source code and release notes.
