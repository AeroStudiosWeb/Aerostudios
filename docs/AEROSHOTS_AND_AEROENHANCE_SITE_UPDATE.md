# AeroStudios Website Update — 23 November 2026

This is a static, GitHub Pages compatible website-only update. **No Rust app, launcher, models, training data or GitHub Release assets are changed.**

## AeroEnhance maintenance notice
- Status: current public build not working. A corrected version is **expected in 1–2 weeks** from 23 November 2026 (estimate, not a guarantee).
- A clear alert appears throughout the website, plus prominent warnings on the AeroEnhance page, downloads page and guide.
- Direct AeroEnhance download buttons are paused in HTML and in `app.js`. The release API will **not reenable them**, even if old ZIPs are present.
- The unified AeroStudio Launcher remains downloadable because other apps are available. The page specifically warns users that the launcher might still list a broken AeroEnhance.
- To reactivate AeroEnhance, verify a corrected release, update all maintenance copy and then set `const aeroEnhancePaused = false` in `docs/app.js`, restore direct link labels and remove the outage notices. **Do not simply change the flag while the old ZIP is still broken.**

## AeroShots by AeroStudio
- New `docs/aeroshots.html` concept page and teasers throughout navigation, homepage, app directory, downloads, guide and individual app pages.
- Describes the planned free worldwide military-aviation photography database: screened uploads with reasons and appeals, searchable aircraft records and photo IDs, profiles, collections, EXIF, awards, first-airframe recognition and assistive metadata.
- Clearly labels mocked database panels as **concept UI**, not a functioning website. No public uploader, signup form or launch-date promise has been created.

## Publish
Copy only the `docs/` folder into your AeroStudios repo, commit and push. Existing GitHub Pages configuration will deploy the change. No change is required to `dist`, `release-out`, AeroEnhance binaries, SHA256 checksums or GitHub Release assets. CSS/JS version query updated to `1.1.0` to reduce stale caching.

## QA
- Open `index.html`, `apps.html`, `aeroshots.html`, `aeroenhance.html`, `downloads.html`, and `guide.html` at phone and desktop widths.
- Verify the mobile menu, new nav links, AeroRoom compare, working application download buttons, and paused AeroEnhance links.
- The repair window is an estimate: update it promptly if the testing schedule changes.
