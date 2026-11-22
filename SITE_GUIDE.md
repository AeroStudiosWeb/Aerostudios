# AeroStudios website — multi-page edition

This is a **static GitHub Pages site**. There are no package managers, CDN dependencies, JavaScript frameworks, or build commands to run. The entire site lives in `docs/` and uses relative links so it works when published under `/AeroStudios/`.

## Pages

- `index.html` — new homepage, app collection, genuine AeroRoom before/after comparison, and unified launcher CTA.
- `apps.html` — four-app directory.
- `aeroroom.html`, `aeroenhance.html`, `aerophoto.html`, `aerofilm.html` — dedicated application pages.
- `downloads.html` — unified launcher, individual app ZIPs and the AeroEnhance CUDA/CPU discovery buttons.
- `guide.html` — installation guidance, including AeroEnhance model setup and troubleshooting.
- `styles.css` — responsive styling and motion, including reduced-motion support.
- `app.js` — mobile menu, scroll reveal, before/after control, clipboard helper and GitHub Release lookup.
- `config.js` — existing GitHub repository and shared release tag configuration; **kept unchanged**.

## Publish

Copy the updated `docs/` into the existing repository's `docs/`, commit the website changes and push to GitHub. Your existing GitHub Pages deployment needs to publish that `docs/` directory, for example via **Settings → Pages → Deploy from a branch → main /docs**. If the site is already configured and working, leave its current deployment setup alone. No new GitHub Release or Rust/launcher rebuild is required for a website-only change.

The existing download system continues to target the shared release tag from `config.js`. The seven fixed-name ZIPs use direct release URLs, and AeroEnhance's versioned `AeroEnhance-v*-Windows-x64-CUDA.zip` (or CPU) is identified via the official GitHub Release API. If the API is unavailable, AeroEnhance buttons link to the release page rather than guessing a ZIP name. The site never asks visitors to download an unsigned model from a third-party mirror.

## AeroEnhance model requirement

The AeroEnhance page, downloads page and getting-started guide explain that the packaged app **does not include SCUNet weights**. After installation:

1. Open `%LOCALAPPDATA%\AeroStudio\Apps\AeroEnhance` when using the unified launcher; or open the extracted `AeroEnhance-Studio` directory for a standalone installation.
2. Run `download-scunet-model.bat`. Its PowerShell helper downloads the SCUNet `.onnx` and `.onnx.data` pair into `models/` and verifies SHA-256 checksums.
3. Restart the application or use **Detect installed** and then enable neural inference.

This is a one-time model download per installation (unless files are replaced/deleted). CUDA may require separate compatible NVIDIA libraries. The third-party model is not made by AeroStudios; do not represent it as an AeroStudios-trained model.

## QA checklist

- Check the new site at desktop and phone widths.
- Check the four individual app pages, their image captions and the model setup instructions.
- Confirm the main launcher link downloads `AeroStudio-Launcher-Windows.zip` from your shared release.
- Confirm the AeroEnhance download link matches the **real published** versioned file name.
- Check that `SHA256SUMS.txt` corresponds to the files in the GitHub Release; the website does not alter ZIP files or hashes.
- Test the AeroRoom comparison slider, mobile menu and copy-path button.
- Avoid moving `dist/` or `release-out/` into `docs/`; compiled packages stay on GitHub Releases.
