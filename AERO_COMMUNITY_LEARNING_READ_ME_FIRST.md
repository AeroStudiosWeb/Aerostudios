# AeroEnhance Community Learning — integrated pilot (v0.8)

**Goal:** improve one shared AeroDenoiseNet using explicitly licensed, curated contributions, then offer signed model updates to users. **Nothing in this repository deploys a worldwide service automatically or silently uploads user photographs.**

This is a privacy-first, invitation-only **operator/pilot implementation**, not a commercial-grade hosted service. Public deployment requires infrastructure, access management, privacy/legal review, security hardening, backups and real-user testing.

## What has been added

1. `services/feedback-server/client_token_admin.py` — issue **individual**, revocable feedback invitations; on disk, store SHA-256 token hashes, not the actual tokens. The Rust server still listens on `127.0.0.1:8787` and must sit behind a real HTTPS reverse proxy for remote access.
2. `training/aero_train/community_review.py` — merge newly opted-in contributions into an operator review CSV. Prior decisions stay intact; new rows default to NO/NO; deleted and expired items disappear.
3. `training/Weekly-AeroLearning.ps1` — review and train weekly candidates on clean human-approved examples; initialise weights from the previous checkpoint rather than learning from scratch; retain general-photo references.
4. `training/aero_train/community_benchmark.py` — compare the **candidate** and the **incumbent** on exactly the same frozen, unrelated benchmark images, using deterministic synthetic noise. Check for improvements in PSNR and no excessive worsening of edge error.
5. `training/aero_train/community_release.py` and `training/Stage-Community-Model.ps1` — generate an **unsigned** model-update proposal only after the fixed benchmark, usual held-out gate, file hash and explicit human-review confirmation pass. The existing Ed25519 signer remains an **offline, manual step**.
6. The AeroEnhance UI and website clarify optional contributions, independent model updates, and the pilot's actual availability.

## What to do with your RUNNING 40-epoch training

**Don't interrupt or replace its output.** Let your current run at `E:\AeroPrivate\runs\general01` complete and review `heldout-report.json`, `aviation-review`, and actual photos. The first accepted candidate can become the **incumbent** for later weekly cycles. Its checkpoint is `E:\AeroPrivate\runs\general01\best.pt`.

You can install it **locally** using `training\Install-LocalModel.ps1`, once quality review has passed. This does not publish anything to users.

## 1 — Keep an independent benchmark

Use photos **never** included in the general training dataset or community contributions, across at least three independent sessions. Your existing aviation dataset may be used initially:

`E:\AeroPrivate\clean-dataset-v2`

The fixed benchmark will become less informative if you repeatedly tune models against it, so later add more *unseen* real-camera evaluation material. The present model uses synthetic noise; this does not demonstrate better real-camera RAW processing than SCUNet or Topaz.

## 2 — Operator: start the private feedback receiver

On a trusted server/machine, create a token list **outside the repository**:

```powershell
python .\services\feedback-server\client_token_admin.py create `
  --file "E:\AeroPrivate\secrets\client-tokens.json" --client-id "pilot001"
```

It displays a randomly generated per-user secret **once**. Give it to that invited pilot privately. Never embed it in the app, commit it, log it, or distribute the whole token file. The `revoke` action disables a token; **restart the server** to apply changes.

```powershell
$env:AERO_CLIENT_TOKENS_FILE="E:\AeroPrivate\secrets\client-tokens.json"
$env:AERO_FEEDBACK_DIR="E:\AeroPrivate\community-feedback"
cargo run --release --manifest-path .\services\feedback-server\Cargo.toml
```

It listens on **127.0.0.1:8787 only**. Local smoke testing can point AeroEnhance at `http://127.0.0.1:8787/v1/contributions`. To involve remote users, the operator must first provision an audited HTTPS reverse proxy, DNS, abuse protection, access logs without photo content, backups, appropriate disk access controls and privacy documentation. Set the in-app community pilot URL to `https://YOUR_DOMAIN/v1/contributions`. **Do not port-forward the raw listener or put one shared beta token in every release.** The server has only in-memory rate limits and local file storage: these are not sufficient as sole protections for unrestricted public usage.

Contributions default to off. The user must click Submit and separately grant image/training permission. Previews are reduced metadata-free PNGs. Feedback without images is useful for product priorities, **not** denoiser training. Before-and-after results are not presumed clean targets. The server deletes contributions after 30 days; direct deletion is supported with a private receipt while the client token is valid. Deletion cannot erase influence from a model already published. Clearly disclose this before any public launch.

## 3 — Weekly review (suggested Friday)

On the operator machine, from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Weekly-AeroLearning.ps1 `
  -Phase Review `
  -FeedbackDir "E:\AeroPrivate\community-feedback" `
  -ReviewCsv "E:\AeroPrivate\community-review\review.csv"
```

Inspect every potential contribution and its original. In the CSV, set **both** `clean_confirmed` and `license_checked` to `YES` only if you have a genuinely clean reference and explicit rights. Provide the correct anonymised `group` so one photographer/session isn't mixed between splits. New entries default to `NO`. All other rows stay unchanged. The enhanced `after.png` is **never** a training target.

## 4 — Weekly private training (suggested Saturday, only after review)

Once the first model is genuinely acceptable, set the incumbent to its `best.pt`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Weekly-AeroLearning.ps1 `
  -Phase Train `
  -FeedbackDir "E:\AeroPrivate\community-feedback" `
  -ReviewCsv "E:\AeroPrivate\community-review\review.csv" `
  -BaseDataset "E:\AeroPrivate\general-dataset" `
  -BenchmarkDataset "E:\AeroPrivate\clean-dataset-v2" `
  -IncumbentCheckpoint "E:\AeroPrivate\runs\general01\best.pt" `
  -RunsRoot "E:\AeroPrivate\community-weekly-runs" `
  -AviationDataset "E:\AeroPrivate\clean-dataset-v2" `
  -Device cuda -Epochs 8 -StepsPerEpoch 200 -Batch 4 `
  -MinNewExamples 10 -ConfirmCuration
```

The script will **skip** when it has fewer than ten approved, still-consented feedback examples, or no changes to the reviewed approved set. It audits the entire training manifest, fine-tunes the prior checkpoint with a **fresh optimizer** (not an unsafe resume on new data), evaluates the usual held-out training split, exports the ONNX, checks aviation examples, then compares candidate and incumbent on the fixed benchmark.

The candidate is stored under the timestamped run directory. The benchmark report is `community-benchmark.json`. **No model is automatically signed, uploaded or installed.** If `MinNewExamples` is too difficult to meet, widen the contribution programme rather than lower quality requirements arbitrarily. Consent expires in 30 days, and future cycles use newly curated examples; older learning persists in the preceding checkpoint.

An optional `training/Register-Community-Schedule.ps1` registers a Windows Task Scheduler task for `-Task Review` (Fridays by default) or `-Task Candidate` (Saturdays by default) using the same paths above. It runs as the current interactive Windows user, so the operator must be logged in. **Candidate scheduling only uses already manually approved rows**. The scripts do not sign, upload, auto-approve, or distribute models. Review changes to the incumbent checkpoint path after each approved promotion. **Approval and release remain manual.** Treat a weekly update as an *opportunity*, not a promise; skip weeks without improvements.

## 5 — Review and stage an update (suggested Sunday)

The operator must review blind comparisons on real noisy photographs (ideally from several camera sensors). A positive synthetic PSNR difference alone is insufficient.

After the weekly candidate has passed *both* held-out and fixed benchmark gates, use a **unique semantic version** and a real HTTPS URL you will upload the ONNX to:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Stage-Community-Model.ps1 `
  -WeeklyRun "E:\AeroPrivate\community-weekly-runs\YYYYMMDD-HHMMSS-XXXXXXXX" `
  -Version "0.2.0" `
  -ModelUrl "https://github.com/AeroStudiosWeb/AeroStudios/releases/download/MODEL-TAG/aero-denoise.onnx" `
  -Output "E:\AeroPrivate\staging\aero-denoise-0.2.0-manifest.json" `
  -HumanReviewed
```

This creates an **UNSIGNED proposal**. The installed app will NOT trust it. Publish only after:

1. Uploading **the exact, hash-matching** ONNX to the proposed public release URL (do not commit giant weights to `docs`).
2. Running `tools/update-signer` *offline* on the staged JSON with your Ed25519 secret key; verify the signature with the matching public key. Never publish the private key or use a sample key.
3. Building AeroEnhance with **`AERO_UPDATE_PUBLIC_KEY_HEX` set to your real Ed25519 public key**, and distributing that trusted build. Signed updates cannot be enabled retroactively in binaries without the key.
4. Copying the signed envelope to `docs/aeroenhance/updates/beta.signed.json` and publishing the website **only once the model asset has been verified**. That path matches AeroEnhance's default beta manifest URL.
5. Having a rollback plan (re-point the signed feed to the last known-good model with a **new signature and newer version**, test rollback) and a clear public privacy notice.

The existing updater verifies Ed25519 signatures and downloaded-model SHA-256. It is opt-in and does not silently upload photographs. Auto-install, if enabled, **installs** the model; it does not automatically activate the new model for existing projects. User control and rollback remain available.

## Important caveats before a public launch

- Pilot invites are not public signup. You'll need user-account onboarding, scalable storage, monitoring, backups, deletion/export processes, security review, and legal/privacy compliance before serving all users.
- **A weekly training schedule is not continuous training by itself.** If too few high-quality examples arrive, keep the incumbent.
- A small number of clean 720-pixel previews can be useful but is not a substitute for licensed, diverse high-resolution clean and aligned noisy/clean datasets. Ratings alone do not supply clean targets.
- Training outcomes cannot be undone after publication by deleting data. Make retention and consent language clear and avoid claiming deletion from trained weights.
- Third-party model weights (e.g. SCUNet) have their own licences and may not be repackaged or used to train derivatives without proper permissions.
- **Unverified here**: live HTTPS hosting, Windows Rust build, remote auth under load, code-signing, and GPU benchmarking. The Python tests are not production certification.
