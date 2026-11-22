/* AeroStudio download integration v0.2.3.
 * Download hrefs are present directly in index.html even when JavaScript fails.
 * The API is solely for optional size/availability labels; it MUST NOT override
 * download links with the release page or disable any download button.
 */
(() => {
  'use strict';
  const config = window.AEROSTUDIO_CONFIG || {};
  const owner = String(config.githubOwner || '').trim();
  const repo = String(config.githubRepo || '').trim();
  const tag = String(config.releaseTag || '').trim();
  const valid = s => /^[A-Za-z0-9_.-]{1,100}$/.test(s);
  const good = valid(owner) && valid(repo) && valid(tag) && !owner.startsWith('YOUR_');
  const status = document.getElementById('release-status');
  const releaseLink = document.getElementById('release-page');
  const repoLink = document.getElementById('footer-repository');
  const links = Array.from(document.querySelectorAll('a[data-asset]'));
  // AeroEnhance's filename includes its app version and GPU variant, so it cannot
  // use the static filename system used by the original three applications.
  const enhanceLinks = Array.from(document.querySelectorAll('a[data-aeroenhance-variant]'));
  const enhanceState = document.getElementById('aeroenhance-state');
  const enhanceMessage = message => { if (enhanceState) enhanceState.textContent = message; };
  const findEnhanceAsset = (assets, variant) => {
    const candidates = assets.filter(asset =>
      typeof asset.name === 'string' &&
      /^AeroEnhance-v[\w.+-]+-Windows-x64-(CUDA|CPU)\.zip$/i.test(asset.name) &&
      asset.name.toUpperCase().endsWith(`-${variant.toUpperCase()}.ZIP`)
    );
    return candidates.sort((a, b) =>
      Date.parse(b.created_at || '') - Date.parse(a.created_at || '') ||
      b.name.localeCompare(a.name)
    )[0] || null;
  };
  const setStatus = text => { if (status) status.textContent = text; };
  const setAssetState = (filename, text) => {
    const span = Array.from(document.querySelectorAll('[data-state]'))
      .find(el => el.dataset.state === filename);
    if (span) span.textContent = text;
  };
  const sizeLabel = bytes => (typeof bytes === 'number' && Number.isFinite(bytes))
    ? `${(bytes / 1048576).toFixed(1)} MB` : 'size unavailable';

  if (!good) {
    // The static download hrefs in HTML remain usable as a safe fallback.
    setStatus('Release configuration missing; use the direct links below.');
  } else {
    const base = `https://github.com/${owner}/${repo}`;
    const release = `${base}/releases/tag/${encodeURIComponent(tag)}`;
    if (repoLink) {
      repoLink.href = base;
      repoLink.removeAttribute('aria-disabled');
    }
    if (releaseLink) {
      releaseLink.href = release;
      releaseLink.removeAttribute('aria-disabled');
    }
    // Until the release API confirms a matching AeroEnhance asset, its button
    // links to the shared release page rather than inventing a ZIP URL.
    enhanceLinks.forEach(link => { link.href = release; });
    // Always construct direct links for the seven existing, fixed-name assets.
    links.forEach(link => {
      const filename = link.dataset.asset || '';
      if (!/^[A-Za-z0-9_.-]+\.zip$/i.test(filename)) return;
      link.href = `${base}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(filename)}`;
      link.classList.remove('disabled-download');
      link.removeAttribute('aria-disabled');
      link.removeAttribute('tabindex');
      link.title = `Download ${filename}`;
    });
    setStatus(`${tag} · Direct downloads available`);

    // Optional metadata; an incomplete or cached API response cannot break links.
    const api = `https://api.github.com/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`;
    fetch(api, { headers: { Accept: 'application/vnd.github+json' }, cache: 'no-store' })
      .then(async response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then(data => {
        const assets = new Map((Array.isArray(data.assets) ? data.assets : [])
          .filter(item => typeof item.name === 'string')
          .map(item => [item.name.toLowerCase(), item]));
        let count = 0;
        links.forEach(link => {
          const file = link.dataset.asset || '';
          const asset = assets.get(file.toLowerCase());
          if (asset) {
            count++;
            setAssetState(file, `Available · ${sizeLabel(asset.size)}`);
          } else {
            setAssetState(file, 'Direct download · metadata unavailable');
          }
          // Intentionally do not modify link.href here.
        });
        // AeroEnhance lives in the SAME release; match its versioned file name.
        // Do not offer a broken direct URL when that file is not attached yet.
        const releaseAssets = Array.isArray(data.assets) ? data.assets : [];
        let availableEnhance = 0;
        enhanceLinks.forEach(link => {
          const variant = String(link.dataset.aeroenhanceVariant || '').toUpperCase();
          if (variant !== 'CUDA' && variant !== 'CPU') return;
          const matched = findEnhanceAsset(releaseAssets, variant);
          if (!matched) {
            link.href = release;
            link.textContent = `${variant} ZIP · view release`;
            if (variant === 'CPU') link.hidden = true;
            return;
          }
          link.hidden = false;
          link.href = `${base}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(matched.name)}`;
          link.textContent = `${variant} ZIP · ${sizeLabel(matched.size)}`;
          link.title = `Download ${matched.name}`;
          availableEnhance++;
        });
        enhanceMessage(availableEnhance
          ? `${availableEnhance} AeroEnhance Windows variant(s) found in ${tag}. GPU users may need compatible NVIDIA drivers and CUDA libraries.`
          : `AeroEnhance isn't attached to ${tag} yet. Add its packaged ZIP to that GitHub Release; the button will update automatically.`);
        setStatus(`${tag} · Direct downloads ready${count ? ` · ${count} file(s) verified` : ''}`);
      })
      .catch(() => {
        setStatus(`${tag} · Direct downloads available (release information not loaded)`);
        enhanceMessage('Could not check AeroEnhance assets automatically. Open the shared GitHub release to see available files.');
        // Keep the AeroEnhance button pointed at the release page; do not invent a URL.
      });
  }

  // Retain AeroRoom's before/after image comparison interaction.
  document.querySelectorAll('[data-compare]').forEach(compare => {
    const range = compare.querySelector('.compare-range');
    const overlay = compare.querySelector('.compare-overlay');
    const divider = compare.querySelector('.compare-divider');
    if (!range || !overlay || !divider) return;
    const update = () => {
      const n = Number(range.value);
      const value = Number.isFinite(n) ? Math.max(0, Math.min(100, n)) : 50;
      overlay.style.width = value + '%';
      divider.style.left = value + '%';
    };
    range.addEventListener('input', update);
    update();
  });
})();
