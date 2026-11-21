/* AeroStudio download links — resilient GitHub Releases integration.
 * Static links are usable before (and without) a GitHub API response.
 * API lookup only verifies names/sizes and identifies mismatches.
 */
(() => {
  'use strict';
  const config = window.AEROSTUDIO_CONFIG || {};
  const owner = String(config.githubOwner || '').trim();
  const repo = String(config.githubRepo || '').trim();
  const tag = String(config.releaseTag || '').trim();
  const validPart = s => /^[A-Za-z0-9_.-]{1,100}$/.test(s);
  const configured = validPart(owner) && !owner.startsWith('YOUR_') &&
                     validPart(repo) && validPart(tag);
  const status = document.getElementById('release-status');
  const links = Array.from(document.querySelectorAll('[data-asset]'));
  const releaseLink = document.getElementById('release-page');
  const repoLink = document.getElementById('footer-repository');
  const setStatus = message => { if (status) status.textContent = message; };
  const setState = (asset, message) => {
    // Asset names are controlled by site markup (not externally injected HTML).
    const el = document.querySelector('[data-state="' + asset + '"]');
    if (el) el.textContent = message;
  };
  const activate = (a, url, description) => {
    a.href = url;
    a.classList.remove('disabled-download');
    a.removeAttribute('aria-disabled');
    a.removeAttribute('tabindex');
    a.title = description;
  };
  const deactivate = (a, description) => {
    a.removeAttribute('href');
    a.classList.add('disabled-download');
    a.setAttribute('aria-disabled', 'true');
    a.setAttribute('tabindex', '-1');
    a.title = description;
    setState(a.dataset.asset, description);
  };
  const formatSize = size => Number.isFinite(size) && size >= 0
    ? `${(size / 1048576).toFixed(1)} MB` : 'file size unknown';

  if (!configured) {
    links.forEach(a => deactivate(a, 'Download configuration is incomplete'));
    setStatus('Downloads not configured. Check docs/config.js.');
  } else {
    const base = `https://github.com/${owner}/${repo}`;
    const releaseUrl = `${base}/releases/tag/${encodeURIComponent(tag)}`;
    const releasesUrl = `${base}/releases`;
    const fileUrl = asset => `${base}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(asset)}`;
    if (repoLink) {
      repoLink.href = base;
      repoLink.removeAttribute('aria-disabled');
    }
    if (releaseLink) {
      releaseLink.href = releaseUrl;
      releaseLink.removeAttribute('aria-disabled');
      releaseLink.textContent = 'Open release files ↗';
    }
    // The previous version disabled everything until a successful API call.
    // Build the standard GitHub download URLs immediately, instead.
    links.forEach(a => {
      const asset = a.dataset.asset;
      if (!/^[A-Za-z0-9_.-]+\.zip$/i.test(asset || '')) {
        deactivate(a, 'Invalid download filename');
        return;
      }
      activate(a, fileUrl(asset), 'Open direct GitHub download (not yet verified)');
      setState(asset, 'Direct release link · checking…');
    });
    setStatus(`${tag} · Direct download links ready; checking GitHub release assets…`);

    const api = `https://api.github.com/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`;
    fetch(api, {headers: {Accept: 'application/vnd.github+json'}})
      .then(async response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then(data => {
        const assets = (Array.isArray(data.assets) ? data.assets : [])
          .filter(item => item.state === 'uploaded' && typeof item.name === 'string');
        const byName = new Map(assets.map(item => [item.name.toLowerCase(), item]));
        let found = 0;
        const missing = [];
        links.forEach(a => {
          const asset = a.dataset.asset;
          const item = byName.get(asset.toLowerCase());
          const safePrefix = `${base}/releases/download/`;
          if (item && typeof item.browser_download_url === 'string' &&
              item.browser_download_url.startsWith(safePrefix)) {
            activate(a, item.browser_download_url, `${item.name} · ${formatSize(item.size)}`);
            setState(asset, `Available · ${formatSize(item.size)}`);
            found++;
          } else {
            // If the API confirms the ZIP is absent, avoid sending people to a 404.
            activate(a, releaseUrl, `${asset} not listed — inspect the GitHub Release`);
            setState(asset, 'Filename not listed · browse release');
            missing.push(asset);
          }
        });
        if (missing.length) {
          setStatus(`${data.name || tag}: ${found}/${links.length} expected ZIP files found. Check the release filenames; missing: ${missing.join(', ')}`);
        } else {
          setStatus(`${data.name || tag} · All ${found} download files confirmed available`);
        }
      })
      .catch(err => {
        // API errors (offline / rate limiting / CORS / 404) must never disable
        // downloads. A direct link uses GitHub's normal release URL instead.
        const reason = err instanceof Error ? err.message : 'network error';
        setStatus(`Could not verify the release (${reason}). Direct download links remain available; check the GitHub release page if a ZIP returns 404.`);
        if (releaseLink && reason.includes('404')) {
          releaseLink.href = releasesUrl;
          releaseLink.textContent = 'Browse all releases ↗';
        }
        links.forEach(a => {
          const asset = a.dataset.asset;
          if (a.hasAttribute('href')) setState(asset, 'Direct link · availability not verified');
        });
      });
  }

  // Keep the site's real before/after slider working.
  document.querySelectorAll('[data-compare]').forEach(compare => {
    const range = compare.querySelector('.compare-range');
    const overlay = compare.querySelector('.compare-overlay');
    const divider = compare.querySelector('.compare-divider');
    if (!range || !overlay || !divider) return;
    const update = () => {
      const value = Math.max(0, Math.min(100, Number(range.value) || 50));
      overlay.style.width = value + '%';
      divider.style.left = value + '%';
    };
    range.addEventListener('input', update);
    update();
  });
})();
