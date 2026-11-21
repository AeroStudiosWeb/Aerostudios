(() => {
  'use strict';
  const config = window.AEROSTUDIO_CONFIG || {};
  const owner = String(config.githubOwner || '');
  const repo = String(config.githubRepo || '');
  const tag = String(config.releaseTag || '');
  const validPart = s => /^[A-Za-z0-9_.-]+$/.test(s) && s.length < 100;
  const configured = validPart(owner) && !owner.startsWith('YOUR_') && validPart(repo) && validPart(tag);
  const status = document.getElementById('release-status');
  const links = Array.from(document.querySelectorAll('[data-asset]'));
  const releaseLink = document.getElementById('release-page');
  const repoLink = document.getElementById('footer-repository');
  const setStatus = message => { status.textContent = message; };
  const deactivate = (a, label) => {
    a.removeAttribute('href'); a.classList.add('disabled-download');
    a.setAttribute('aria-disabled', 'true'); a.setAttribute('tabindex', '-1');
    a.removeAttribute('download'); a.title = label;
    const state = document.querySelector('[data-state="' + a.dataset.asset + '"]');
    if (state) state.textContent = label;
  };
  links.forEach(a => deactivate(a, 'Not published yet'));
  if (!configured) {
    setStatus('Downloads are being prepared — repository not configured yet.');
    return;
  }
  const base = `https://github.com/${owner}/${repo}`;
  repoLink.href = base;
  repoLink.removeAttribute('aria-disabled');
  releaseLink.href = `${base}/releases/tag/${encodeURIComponent(tag)}`;
  releaseLink.removeAttribute('aria-disabled');
  releaseLink.textContent = 'All release files ↗';
  const api = `https://api.github.com/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`;
  fetch(api, {headers:{Accept:'application/vnd.github+json'}})
    .then(async response => {
      if (!response.ok) throw new Error(`Release unavailable (${response.status})`);
      return response.json();
    })
    .then(data => {
      const assets = new Map((Array.isArray(data.assets) ? data.assets : []).filter(a => a.state === 'uploaded').map(a => [a.name, a]));
      let count = 0;
      links.forEach(a => {
        const item = assets.get(a.dataset.asset);
        if (!item || typeof item.browser_download_url !== 'string') return;
        // Only link to a correctly scoped release download on GitHub.
        const safePrefix = `${base}/releases/download/`;
        if (!item.browser_download_url.startsWith(safePrefix)) return;
        a.href = item.browser_download_url;
        a.classList.remove('disabled-download');
        a.removeAttribute('aria-disabled'); a.removeAttribute('tabindex');
        a.title = item.name;
        const state = document.querySelector('[data-state="' + a.dataset.asset + '"]');
        if (state) state.textContent = `Available · ${formatSize(item.size)}`;
        count++;
      });
      const version = data.name || tag;
      setStatus(count ? `${version} · ${count} download${count !== 1 ? 's' : ''} available` : `${version} · Windows builds are not uploaded yet`);
    })
    .catch(() => {
      setStatus('Release information unavailable — try the releases page.');
      // If GitHub API is down or rate-limited, the release page remains usable.
    });
  function formatSize(bytes) {
    return Number.isFinite(bytes) && bytes >= 0 ? `${(bytes / 1048576).toFixed(1)} MB` : 'Windows';
  }
})();
