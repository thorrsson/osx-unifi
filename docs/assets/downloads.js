(async function () {
  const links = Array.from(document.querySelectorAll('[data-download="mac"]'));
  const status = document.querySelector('[data-download-status]');
  if (links.length === 0) return;

  const agent = navigator.userAgent || '';
  const platform = navigator.userAgentData?.platform || navigator.platform || '';
  const isMac = /Mac/i.test(platform) &&
    !/iPhone|iPad|iPod/i.test(agent) &&
    !(navigator.maxTouchPoints > 1);

  const messages = [];
  function showStatus() {
    if (!status || messages.length === 0) return;
    status.textContent = messages.join(' ');
    status.hidden = false;
  }

  if (!isMac) {
    messages.push('UniFi Desktop is a Mac app. It needs macOS 14 Sonoma or later on an Apple silicon or Intel Mac.');
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetch('https://api.github.com/repos/thorrsson/osx-unifi/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
      signal: controller.signal,
    });
    if (response.status === 404) {
      messages.push('No release has been published yet. Download links open the releases page.');
      return;
    }
    if (!response.ok) throw new Error(`GitHub returned HTTP ${response.status}`);
    const release = await response.json();
    if (!Array.isArray(release.assets)) throw new Error('GitHub returned no release assets');

    const asset = release.assets.find(asset =>
      typeof asset.name === 'string' &&
      asset.name.startsWith('UniFiDesktop-') &&
      asset.name.endsWith('.dmg')
    );
    if (!asset) {
      messages.push('The latest release has no disk image. Download links open the release page instead.');
      return;
    }
    const url = new URL(asset.browser_download_url);
    if (url.origin !== 'https://github.com' ||
        !url.pathname.startsWith('/thorrsson/osx-unifi/releases/download/')) {
      throw new Error('GitHub returned an unexpected download URL');
    }
    const version = typeof release.tag_name === 'string' ? release.tag_name.replace(/^v/, '') : '';
    for (const link of links) {
      link.href = url.href;
      if (link.dataset.downloadLabel === 'version' && /^\d+\.\d+\.\d+$/.test(version)) {
        link.textContent = `Download UniFi Desktop ${version}`;
      }
    }
  } catch (error) {
    console.error('Could not resolve the UniFi Desktop download:', error);
    messages.push('Direct downloads are temporarily unavailable. Download links open the latest release page instead.');
  } finally {
    clearTimeout(timeout);
    showStatus();
  }
})();
