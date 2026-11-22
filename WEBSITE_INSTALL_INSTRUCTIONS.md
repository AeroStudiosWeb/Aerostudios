# AeroEnhance on the existing AeroStudio homepage

Based on the uploaded `Aerostudios-main.zip` repository snapshot. This integration deliberately modifies only:

- `docs/index.html` — a fourth app feature card and a download row for AeroEnhance
- `docs/app.js` — looks for AeroEnhance versioned CUDA/CPU ZIPs in the **existing** release configured by `docs/config.js`
- `docs/styles.css` — styles the new feature card and optional download controls

The other three apps and their direct download buttons are unchanged. No standalone `aeroenhance.html` or `aeroenhance-download.js` file is needed. The existing homepage already uses a single release tag from `docs/config.js`.

## How to use

1. In your local AeroStudios GitHub repository, replace `docs/index.html`, `docs/app.js` and `docs/styles.css` with the three files in this ZIP. Keep all other `docs` assets and `docs/config.js`.
2. Open `docs/config.js` and check `releaseTag` is the exact **existing** shared GitHub Release to which you are attaching AeroEnhance. In the uploaded repo it is `v0.1.0-beta.1`; leave that unchanged if you're using that release.
3. On the GitHub release, upload the actual distributable AeroEnhance CUDA ZIP from your local `dist/`, **not** this source-code ZIP. The expected pattern produced by the existing packager is `AeroEnhance-v<internal-version>-Windows-x64-CUDA.zip`. You can add the `.sha256` checksum too. The page also recognises an optional CPU ZIP named similarly.
4. Commit and push the three website file changes using GitHub Desktop. Let GitHub Pages deploy your `docs` branch/folder.
5. Open your homepage. It now shows AeroEnhance in the existing app showcase and download list. With an accessible release API, the CUDA button becomes a direct versioned ZIP link as soon as the asset appears. Until then it opens the existing release page; it never manufactures a broken link.

Important: the current unified launcher still lists AeroRoom, AeroFilm and AeroPhoto only. The new AeroEnhance website button downloads a **standalone app ZIP**, not a launcher integration. Model installation and GPU requirements remain separate. Test on a clean Windows PC before announcing public availability.

## What was verified

- Exact original homepage structure and release tag from the uploaded source
- Static markup and linked assets preserved for the other three apps
- JavaScript parse check and simulated GitHub release API tests with/without AeroEnhance ZIP

This change has not been pushed to your actual GitHub repository or deployed to GitHub Pages.
