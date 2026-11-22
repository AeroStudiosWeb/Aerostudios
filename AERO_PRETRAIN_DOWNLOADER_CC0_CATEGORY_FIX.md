# AeroStudios v0.7.2 — CC0 downloader fix

**Problem:** Generic Wikimedia full-text searches returned only two strictly allowed CC0 images.

**Fix:** The downloader uses the large Commons `Category:CC-Zero` directly through the MediaWiki `generator=categorymembers` API, starts searches at several filename prefixes to diversify candidates, verifies each file's individual licence, requires a named creator, caps per-creator contribution and resumes the prior source ledger. Search fallback is retained.

Use from repository root (replace contact email):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Build-General-Dataset.ps1 `
  -Phase Download -Workspace "E:\AeroPrivate" -TargetImages 500 `
  -Contact "YOUR_REAL_EMAIL@example.com" -LicenseMode CC0 `
  -Discovery Auto -MaxPerCreator 30
```

**Keep your local `.venv`, `dist`, `release-out` and E:\AeroPrivate folders.** The ZIP is a source replacement, not your compiled apps or private dataset.

This change does not remove the manual review stage. Open `E:\AeroPrivate\general-commons\SOURCE_LICENSE_REVIEW.csv` and approve/reject every entry only after checking suitability, source and licence.

The direct category query is documented at https://www.mediawiki.org/wiki/API:Categorymembers ; the Commons category is https://commons.wikimedia.org/wiki/Category:CC-Zero .
