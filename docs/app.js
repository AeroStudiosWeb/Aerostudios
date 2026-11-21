/* AeroStudio download integration v0.2.2.
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
    // Always construct direct links. Never point individual buttons at /releases/tag/.
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
        setStatus(`${tag} · Direct downloads ready${count ? ` · ${count} file(s) verified` : ''}`);
      })
      .catch(() => {
        setStatus(`${tag} · Direct downloads available (release information not loaded)`);
        // Intentionally do not modify link.href here.
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
