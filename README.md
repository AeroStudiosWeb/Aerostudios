# AeroStudio — GitHub Website & Windows Downloads

This is a ready-to-publish **GitHub Pages website** and **Windows release-packaging kit** for the three AeroStudio apps:

- **AeroRoom Studio** — aviation RAW photo editor.
- **AeroFilm Studio** — aviation video editor.
- **AeroPhoto Studio** — aviation layered image editor.

The website has **seven separate download choices**: the three apps, a standalone launcher for each app, and the unified **AeroStudio Launcher**.

> **Important:** This ZIP contains the finished website, launchers' source scripts and release-builder script. It **does not contain Windows executables**. Your already-compiled `.exe` files are on your Windows PC; only you can package/upload them. The website enables buttons after the corresponding ZIP assets are uploaded to GitHub Releases.

## Quick setup — easiest route (GitHub Desktop)

1. Sign in to [GitHub](https://github.com/) and create a **public empty repository** named `AeroStudio` (do not tick "Add README"). You can use a different repository name, but remember it for the next step.
2. Extract this kit. Open [GitHub Desktop](https://desktop.github.com/) and use **File → Add local repository**; select this extracted folder. If prompted, create a Git repository here. Publish it to GitHub under your account and repository name. **Keep `.github`, `docs`, `launcher-template`, `licenses`, `tools` and `README.md`**. They are all needed.
3. On **your Windows PC**, confirm all three compiled executables are installed. Usually they are:
   - `%LOCALAPPDATA%\AeroStudio\Apps\AeroRoom\AeroRoomStudio.exe`
   - `%LOCALAPPDATA%\AeroStudio\Apps\AeroFilm\AeroFilmStudio.exe`
   - `%LOCALAPPDATA%\AeroStudio\Apps\AeroPhoto\AeroPhotoStudio.exe`
4. Open CMD **in this extracted folder** and run (replace `YOUR_USERNAME`):

   ```cmd
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Make-Windows-Release.ps1 -Owner YOUR_USERNAME -Repository AeroStudio -Tag v0.1.0-beta.1
   ```

   If your app binaries live elsewhere, pass `-AeroRoomExe "C:\path\AeroRoomStudio.exe"`, `-AeroFilmExe`, and/or `-AeroPhotoExe`.

5. The script produces **seven ZIPs** and `SHA256SUMS.txt` in `release-out\` and updates `docs\config.js` with your GitHub repository info. Do not upload `release-out` as regular repo files (it's in `.gitignore`). In GitHub Desktop, commit and **push** the changed `docs/config.js`.
6. On GitHub open **Settings → Pages** and select **GitHub Actions** as the publishing source. The included `.github/workflows/pages.yml` deploys `docs/` automatically. Open the Actions tab to check the deploy. The URL will usually be `https://YOUR_USERNAME.github.io/AeroStudio/`.
7. On GitHub go to **Releases → Draft a new release**. Create the tag `v0.1.0-beta.1` (exactly matching the command). Optionally mark it **pre-release**. Upload **all seven ZIPs** and `SHA256SUMS.txt` from `release-out/`, add release notes, and publish.
8. Refresh the AeroStudio website. It will query GitHub's release API for that specific tag and automatically activate the download buttons whose assets are present. Verify each download yourself on Windows before announcing the site publicly.

### Direct release ZIP filenames (must match exactly)

| Release asset | Description |
| --- | --- |
| `AeroStudio-Launcher-Windows.zip` | Main launcher; manages all three applications |
| `AeroRoom-Launcher-Windows.zip` | Individual AeroRoom installer/launcher |
| `AeroFilm-Launcher-Windows.zip` | Individual AeroFilm installer/launcher |
| `AeroPhoto-Launcher-Windows.zip` | Individual AeroPhoto installer/launcher |
| `AeroRoom-Windows.zip` | AeroRoom Windows executable + licences |
| `AeroFilm-Windows.zip` | AeroFilm Windows executable + licences |
| `AeroPhoto-Windows.zip` | AeroPhoto Windows executable + licences |

### Do visitors need Rust?

**No.** For the release ZIPs, visitors download the precompiled `.exe` or a launcher that installs it. Rust, Cargo and Visual Studio are needed to **build from source**, not to run the released apps.

### What the launchers do

- The main launcher is a Windows Forms/PowerShell GUI, derived from the already-tested development launcher.
- The three small individual launchers each expose **Download/Install**, **Launch**, and **Install ZIP**.
- Downloaded app ZIPs are protected by SHA-256 checksums **embedded when you package the release**. A checksum mismatch blocks installation.
- Apps install separately to `%LOCALAPPDATA%\AeroStudio\Apps\<App>\` and keep separate settings/catalogues.
- Existing app installations are not deleted when launchers are installed.
- Launcher download links are pinned to the **release tag** you used when building the packages. For updates, rebuild/re-upload the launcher ZIPs with new checksums.

## Updating the website

Edit files in `docs/`, commit and push. GitHub Actions redeploys the site.

## Updating an application release

Rebuild the Rust app on Windows. Create a **new tag**, e.g. `v0.1.0-beta.2`. Run `Make-Windows-Release.ps1` again with the new tag. Upload the seven new ZIPs under the new tag, and commit the updated `docs/config.js`. This ensures the website and launchers use a consistent version.

## How to test the website locally

Open a terminal in the repo root and run:

```cmd
python -m http.server 8000 -d docs
```

Then visit `http://localhost:8000/`. The landing page works even when no release is published; download buttons remain disabled rather than linking to missing files.

## Packaging and quality notes

- Test **all three** released Windows executables on a clean Windows machine or a separate Windows user account before inviting public downloads.
- Windows may warn about unsigned development software; sign the executables before a larger public rollout if possible.
- GitHub Actions in this repository **deploys the website only**. It does not automatically build Rust applications, because their native build requirements, runtime assets and code-signing have not been verified in an automated CI runner.
- Keep upstream MIT/Apache notices and font/licence requirements with binary distributions; a separate `LICENSING.md` explains this.
- Never publish private RAWs, customer files, tokens or passwords. The supplied hero photograph is the AeroRoom aircraft image provided during development; remove `docs/assets/f35-aeroroom-export.jpg` if you do not want it published publicly.

## Project layout

```
.github/workflows/pages.yml     GitHub Pages auto-deploy
.github/ISSUE_TEMPLATE/        Bug reports and feature requests
docs/                           Entire responsive website
docs/config.js                 GitHub repo and version tag
launcher-template/              Rust-free Windows launcher source
licenses/                       Upstream licence/attribution files
tools/Make-Windows-Release.ps1  Creates all seven release packages
release-out/                    Generated locally; never commit to website repo
```

**Website and launcher kit prepared for AeroStudio.** The underlying applications are independent forks of LightCraft, FilmCraft and PhotoCraft. See `LICENSING.md` and include original copyright notices in public distributions.
