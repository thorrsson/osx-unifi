---
title: Managing your network
description: What each page of UniFi Desktop shows, and how to create, edit and delete settings on your UniFi console.
permalink: /managing/
---

# Managing your network

UniFi Desktop shows the selected site in a sidebar layout like the UniFi console. **Dashboard**, **UniFi Devices** and **Client Devices** show what's on your network. The **Settings** pages, **Networks**, **WiFi**, **Firewall**, **DNS** and **Hotspot**, let you create, edit and delete configuration.

## How editing works

- **Create** with the button at the top right of a page, such as **Create Network**.
- **Edit** a row by double-clicking it, or choose **Edit…** from its Control-click menu. The editor opens in a panel on the right. Click **Apply Changes** to save or **Cancel** to discard.
- **Turn items on or off** with the switch in the **Enabled** column.
- **Delete** from the Control-click menu, or from the editor. Deleting always asks you to confirm first.
- **Refresh** everything from the console with the toolbar button or <kbd>⌘</kbd><kbd>R</kbd>. The app doesn't poll in the background, so refresh to see changes made elsewhere.

Built-in (system-defined) items, such as the console's own firewall policies and zones, are shown for reference and can't be edited.

### Your other settings are kept

Each editor starts from the console's current copy of the item and changes only the fields it shows. Settings the app doesn't display, such as advanced WiFi options or firewall schedules, are sent back exactly as they were.

### Every change has a clear result

The app sends each change once and never retries it automatically. Then it tells you what happened:

- **Accepted**: the console confirmed the change. A confirmation appears briefly and the affected page reloads.
- **Rejected**: the console refused the change and nothing was changed. The console's reason is shown, for example a VLAN ID that's already in use.
- **Unconfirmed**: the connection dropped or the console's reply didn't match, so the outcome is unknown. Refresh and check before trying again.

<div class="callout warning" markdown="1">
Some changes can interrupt your own connection to the console, for example restarting the gateway or changing the network your Mac is on. The console accepting a request doesn't mean a restart has finished.
</div>

## Dashboard

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/dashboard.png' | relative_url }}" alt="Dashboard with gateway status, WAN interfaces and summary counts" loading="lazy" width="1280" height="820">
</figure>

Gateway health and statistics, WAN interfaces, and counts of devices, clients, networks and WiFi networks for the selected site. Click a summary to go to its page.

## UniFi Devices

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/devices.png' | relative_url }}" alt="UniFi Devices table with a device's details open on the right" loading="lazy" width="1280" height="820">
</figure>

Every adopted gateway, switch and access point with its model, IP address, firmware and status. Double-click a device to see its details, latest statistics, ports and radios.

- **Restart…** restarts a device.
- **Power cycle port** briefly cuts PoE power to a switch port, restarting whatever it powers. Find it next to the port in the device's **Ports** section.
- **Adopt** adopts a device that's waiting to be adopted. Those devices appear under **Ready to Adopt**, and the sidebar shows how many are waiting.
- **Remove…** removes (forgets) an adopted device from the console.

## Client Devices

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/clients.png' | relative_url }}" alt="Client Devices table listing wired, wireless and guest clients" loading="lazy" width="1280" height="820">
</figure>

Connected wired, wireless and VPN clients with their IP and MAC addresses, the device they're connected through, and when they connected.

For guests on a hotspot network:

- **Authorize Guest** grants access with your site's hotspot defaults.
- Double-click the guest to authorize with your own **time**, **data**, **download** and **upload** limits.
- **Revoke Guest Access…** removes an authorized guest's access.

## Networks

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/network-editor.png' | relative_url }}" alt="Network editor with General, Gateway, DHCP and Advanced sections" loading="lazy" width="1280" height="820">
</figure>

Create and edit networks: name, VLAN ID, gateway IP and subnet, DHCP server or relay with its range and DNS servers, network isolation, internet access, multicast DNS, and firewall zone.

Before deleting a network, the app asks the console what still uses it, such as WiFi networks or firewall settings, and warns you before deleting a network that's in use.

## WiFi

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/wifi-editor.png' | relative_url }}" alt="WiFi editor with name, network, security and band settings" loading="lazy" width="1280" height="820">
</figure>

Create and edit WiFi networks: name (SSID), the network it belongs to, 2.4, 5 and 6 GHz bands, band steering, security (open, WPA2, WPA2/WPA3 or WPA3 Personal) and password, hiding the WiFi name, and client device isolation.

WiFi networks that use Enterprise (RADIUS) security or another mode the app doesn't edit keep their security settings untouched. Change those in the web UI.

## Firewall

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/firewall-policy.png' | relative_url }}" alt="Firewall policies list with a policy editor open on the right" loading="lazy" width="1280" height="820">
</figure>

The **Policies** view lists zone-based firewall policies in evaluation order. Create and edit a policy's name, source and destination zones, action (allow, block or reject), IP version, return traffic, and syslog logging.

Control-click a custom policy to change its order:

- **Move Up** and **Move Down** move it within the same source and destination zone pair.
- **Evaluate Before Built-in Policies** and **Evaluate After Built-in Policies** place it ahead of or behind the console's own policies.

On UniFi Network 11, policies can also **report flows**. Choose **Report Flows** or **Stop Reporting Flows** from the Control-click menu, or use the toggle in the editor.

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/firewall-zones.png' | relative_url }}" alt="Firewall zones list showing each zone's networks" loading="lazy" width="1280" height="820">
</figure>

Switch to the **Zones** view to create, rename and delete firewall zones and choose which networks belong to each one.

Detailed traffic matching, such as ports, IP groups, apps or schedules, is kept as-is. Use **Open Firewall Settings in Web UI** to change it.

## DNS

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/dns.png' | relative_url }}" alt="DNS records table" loading="lazy" width="1280" height="820">
</figure>

Local DNS records served by your gateway: **A**, **AAAA**, **CNAME**, **TXT**, **MX** and **SRV** records, plus **forward domains** that send lookups for a domain to another DNS server.

## Hotspot

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/voucher-form.png' | relative_url }}" alt="Create Vouchers sheet with quantity, duration, guest and limit settings" loading="lazy" width="1280" height="820">
</figure>

Click **Create Vouchers** to make one or more vouchers at once. Choose how long they last, how many guests can use each voucher, and optional data and speed limits. Limits you leave off use your site's hotspot defaults.

<figure>
  <img class="screenshot" src="{{ '/assets/screenshots/vouchers-created.png' | relative_url }}" alt="New voucher codes ready to copy" loading="lazy" width="1280" height="820">
</figure>

New codes are shown right away. Click **Copy All** to copy them to the clipboard. In the vouchers list you can copy or delete selected vouchers, or use **Delete Expired…** to clean up.

## What the app doesn't manage

UniFi Desktop only uses the official, documented UniFi Network API. It doesn't aim to match every setting in the UniFi web UI. For example, it doesn't manage:

- Port forwarding, VPN, routing, and traffic or content filtering.
- Device settings such as LEDs, port profiles and radio channels.
- Detailed firewall traffic matching and schedules.
- Console settings, users and admins, UniFi Protect and other UniFi apps.

Click **Open in Web UI** in the toolbar to open the matching page of your console's web UI in your browser. You may need to sign in to the console there.
