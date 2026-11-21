
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
  const setStatus = message => { if (status) status.textContent = message; };
  const deactivate = (a, label) => {
    a.removeAttribute('href');
    a.classList.add('disabled-download');
    a.setAttribute('aria-disabled', 'true');
    a.setAttribute('tabindex', '-1');
    a.title = label;
    const state = document.querySelector('[data-state="' + a.dataset.asset + '"]');
    if (state) state.textContent = label;
  };
  links.forEach(a => deactivate(a, 'Not published yet'));

  if (configured) {
    const base = `https://github.com/${owner}/${repo}`;
    if (repoLink) {
      repoLink.href = base;
      repoLink.removeAttribute('aria-disabled');
    }
    if (releaseLink) {
      releaseLink.href = `${base}/releases/tag/${encodeURIComponent(tag)}`;
      releaseLink.removeAttribute('aria-disabled');
    }
    const api = `https://api.github.com/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`;
    fetch(api, { headers: { Accept: 'application/vnd.github+json' } })
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
          const safePrefix = `${base}/releases/download/`;
          if (!item.browser_download_url.startsWith(safePrefix)) return;
          a.href = item.browser_download_url;
          a.classList.remove('disabled-download');
          a.removeAttribute('aria-disabled');
          a.removeAttribute('tabindex');
          a.title = item.name;
          const state = document.querySelector('[data-state="' + a.dataset.asset + '"]');
          if (state) state.textContent = `Available · ${formatSize(item.size)}`;
          count++;
        });
        setStatus(count ? `${data.name || tag} · ${count} downloads available` : `${data.name || tag} · Windows builds are not uploaded yet`);
      })
      .catch(() => {
        setStatus('Release information unavailable — use the release page directly.');
      });
  } else {
    setStatus('Downloads are being prepared — repository not configured yet.');
  }

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

  function formatSize(bytes) {
    return Number.isFinite(bytes) && bytes >= 0 ? `${(bytes / 1048576).toFixed(1)} MB` : 'Windows';
  }
})();
