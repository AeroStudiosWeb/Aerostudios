/* AeroStudios GitHub Pages site v1.0 — progressive enhancement.
   Download URLs are always GitHub URLs, no client credentials or photo uploads. */
(() => {
  'use strict';
  const config = window.AEROSTUDIO_CONFIG || {};
  const owner = String(config.githubOwner || '').trim();
  const repo = String(config.githubRepo || '').trim();
  const tag = String(config.releaseTag || '').trim();
  const valid = value => /^[A-Za-z0-9_.-]{1,100}$/.test(value);
  const configured = valid(owner) && valid(repo) && valid(tag) && !owner.startsWith('YOUR_');
  const base = configured ? `https://github.com/${owner}/${repo}` : 'https://github.com/AeroStudiosWeb/AeroStudios';
  const release = configured ? `${base}/releases/tag/${encodeURIComponent(tag)}` : `${base}/releases`;
  const $ = selector => document.querySelector(selector);
  const $$ = selector => Array.from(document.querySelectorAll(selector));

  // Responsive menu: semantic button, explicit aria-expanded and click-away closing.
  const toggle = $('.menu-toggle');
  const mobile = $('#mobile-nav');
  if (toggle && mobile) {
    const show = open => {
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', open ? 'Close navigation menu' : 'Open navigation menu');
      mobile.hidden = !open;
    };
    show(false);
    toggle.addEventListener('click', () => show(toggle.getAttribute('aria-expanded') !== 'true'));
    mobile.querySelectorAll('a').forEach(link => link.addEventListener('click', () => show(false)));
    document.addEventListener('keydown', event => { if (event.key === 'Escape') show(false); });
    document.addEventListener('click', event => {
      if (!mobile.hidden && !mobile.contains(event.target) && !toggle.contains(event.target)) show(false);
    });
  }
  const header = $('.site-header');
  const setScrolled = () => { if (header) header.classList.toggle('is-scrolled', scrollY > 20); };
  window.addEventListener('scroll', setScrolled, { passive:true });
  setScrolled();

  // Entrances respect reduced-motion preference and never hide content without JS.
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const reveal = $$('.reveal');
  if (reduced || !('IntersectionObserver' in window)) reveal.forEach(el => el.classList.add('is-visible'));
  else {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => { if (entry.isIntersecting) { entry.target.classList.add('is-visible'); observer.unobserve(entry.target); } });
    }, { threshold:.08, rootMargin:'0px 0px -25px 0px' });
    reveal.forEach(el => observer.observe(el));
  }

  // Accessible AeroRoom comparison. Set overlay image to its parent's width to
  // prevent the before photo from stretching when the slider moves.
  $$('[data-compare]').forEach(compare => {
    const input = compare.querySelector('input[type="range"]');
    if (!input) return;
    const update = () => {
      const value = Math.max(0, Math.min(100, Number(input.value) || 0));
      compare.style.setProperty('--split', value + '%');
      compare.style.setProperty('--compare-width', compare.clientWidth + 'px');
    };
    input.addEventListener('input', update);
    update();
    if ('ResizeObserver' in window) new ResizeObserver(update).observe(compare);
    else window.addEventListener('resize', update);
  });

  // Clipboard functionality is optional; show a clear fallback if blocked.
  $$('[data-copy]').forEach(button => button.addEventListener('click', async () => {
    const value = button.getAttribute('data-copy');
    const original = button.textContent;
    try {
      if (!navigator.clipboard) throw Error('Clipboard unavailable');
      await navigator.clipboard.writeText(value);
      button.textContent = 'Copied ✓';
    } catch (_) { button.textContent = 'Select the path'; }
    window.setTimeout(() => { button.textContent = original; }, 1900);
  }));

  // Guide side navigation highlight (doesn't block normal hash links).
  const guideLinks = $$('.guide-sidebar-sticky a[href^="#"]');
  if (guideLinks.length && 'IntersectionObserver' in window) {
    const sections = guideLinks.map(a => $(a.getAttribute('href'))).filter(Boolean);
    const navObserver = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) guideLinks.forEach(a => a.classList.toggle('is-active', a.getAttribute('href') === '#' + entry.target.id));
      });
    }, { rootMargin:'-20% 0px -65% 0px' });
    sections.forEach(el => navObserver.observe(el));
  }

  // GitHub release metadata is optional, never required for the static website.
  const normalLinks = $$('a[data-asset]');
  const enhanceLinks = $$('a[data-aeroenhance-variant]');
  const status = $('#release-status');
  const version = $('#release-version');
  if (version && configured) version.textContent = tag;
  $$('a#release-page, a#downloads-release').forEach(a => a.href = release);
  $$('a#footer-repository').forEach(a => a.href = base);
  const setStatus = value => { if (status) status.textContent = value; };
  const setEnhanceStatus = value => $$('[data-aeroenhance-status]').forEach(el => { el.textContent = value; });
  const size = bytes => typeof bytes === 'number' && Number.isFinite(bytes) ? (bytes / 1048576).toFixed(1) + ' MB' : 'Windows ZIP';
  const enhanceRegex = /^AeroEnhance-v[\w.+-]+-Windows-x64-(CUDA|CPU)\.zip$/i;
  const matchesVariant = (asset, variant) => typeof asset.name === 'string' && enhanceRegex.test(asset.name) && asset.name.toUpperCase().endsWith(`-${variant}.ZIP`);
  const matching = (assets, variant) => assets.filter(a => matchesVariant(a, variant)).sort((a,b) => Date.parse(b.created_at || 0) - Date.parse(a.created_at || 0) || b.name.localeCompare(a.name))[0];
  enhanceLinks.forEach(link => { link.href = release; });
  if (!configured) { setStatus('Use the official GitHub Release for downloads.'); setEnhanceStatus('Release configuration missing — browse the GitHub Release for files.'); return; }
  normalLinks.forEach(link => {
    const filename = link.dataset.asset || '';
    if (!/^[A-Za-z0-9_.-]+\.zip$/i.test(filename)) return;
    link.href = `${base}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(filename)}`;
    link.title = `Download ${filename}`;
  });
  setStatus(`${tag} · Downloads hosted on GitHub`);
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 12000);
  fetch(`https://api.github.com/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`,
    { headers:{Accept:'application/vnd.github+json'}, signal:controller.signal })
    .then(response => { if (!response.ok) throw Error(`GitHub API ${response.status}`); return response.json(); })
    .then(data => {
      const assets = Array.isArray(data.assets) ? data.assets.filter(a => typeof a.name === 'string') : [];
      const map = new Map(assets.map(a => [a.name.toLowerCase(),a]));
      const count = new Set();
      normalLinks.forEach(link => {
        const filename = String(link.dataset.asset || '');
        const item = map.get(filename.toLowerCase());
        if (item) count.add(filename.toLowerCase());
        $$('[data-state]').filter(el => el.dataset.state === filename).forEach(el => {
          el.textContent = item ? `Available · ${size(item.size)}` : 'File not listed · check GitHub release';
        });
        // Avoid a known broken direct URL if the release API confirms it's absent.
        if (!item) { link.href = release; link.title = 'File not listed; browse the official release'; }
      });
      const foundVariants = new Set();
      enhanceLinks.forEach(link => {
        const variant = String(link.dataset.aeroenhanceVariant || '').toUpperCase();
        if (variant !== 'CUDA' && variant !== 'CPU') return;
        const item = matching(assets, variant);
        if (item) {
          foundVariants.add(variant);
          link.hidden = false;
          link.href = `${base}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(item.name)}`;
          link.textContent = `Download ${variant} · ${size(item.size)} ↗`;
          link.title = item.name;
        } else {
          link.href = release;
          link.hidden = variant === 'CPU';
          link.textContent = 'Browse GitHub release ↗';
        }
      });
      setEnhanceStatus(foundVariants.size ? `${foundVariants.size} AeroEnhance Windows variant${foundVariants.size===1?'':'s'} available · GitHub Releases` : 'No AeroEnhance ZIP was found in this release. Browse GitHub Releases.');
      setStatus(`${tag} · ${count.size} fixed-name ZIP${count.size===1?'':'s'} listed`);
    })
    .catch(() => {
      setStatus(`${tag} · Direct links available · GitHub metadata unavailable`);
      setEnhanceStatus('Live release lookup unavailable. Browse the official GitHub Release to download AeroEnhance.');
      // The original three fixed-name app ZIPs keep their direct links.
      enhanceLinks.forEach(link => { link.href = release; link.textContent = 'Browse GitHub release ↗'; });
    })
    .finally(() => window.clearTimeout(timeout));
})();
