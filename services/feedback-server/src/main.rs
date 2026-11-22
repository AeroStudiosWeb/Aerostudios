//! Private beta intake, NOT an AI training service.
//! Designed to bind to 127.0.0.1, behind an authenticated HTTPS reverse proxy
//! if remote users are ever enabled. Never expose this HTTP listener directly.
use anyhow::{Context, Result};
use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get, post}, Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{path::{Path as FsPath, PathBuf}, sync::Arc, time::{SystemTime, UNIX_EPOCH, Duration, Instant}};
use subtle::ConstantTimeEq;
use tokio::sync::Mutex;
use uuid::Uuid;

const CONSENT: &str = "2026-11-beta-v2-training";
const LEGACY_CONSENT: &str = "2026-11-beta-v1";
const MAX_BYTES: usize = 14 * 1024 * 1024;
const MAX_PNG_BYTES: usize = 5 * 1024 * 1024;
const RETAIN_SECS: u64 = 30 * 24 * 60 * 60;

type ApiResult<T> = std::result::Result<T, (StatusCode, String)>;
fn bad(msg: &str) -> (StatusCode, String) { (StatusCode::BAD_REQUEST, msg.into()) }
fn internal() -> (StatusCode, String) { (StatusCode::INTERNAL_SERVER_ERROR, "Storage temporarily unavailable".into()) }

#[derive(Clone)]
struct AppState {
    token: Arc<String>,
    data_dir: Arc<PathBuf>,
    rate: Arc<Mutex<Vec<Instant>>>,
}
#[derive(Debug, Deserialize)]
struct Contribution {
    consent_version: String,
    app_version: String,
    model_label: String,
    rating: String,
    issue: String,
    note: String,
    before_png_b64: Option<String>,
    after_png_b64: Option<String>,
    #[serde(default)]
    training_permission: bool,
}
#[derive(Debug, Serialize)]
struct Receipt { id: String, deletion_secret: String }
#[derive(Debug, Serialize, Deserialize)]
struct StoredMeta {
    id: String,
    created_unix: u64,
    expires_unix: u64,
    consent_version: String,
    app_version: String,
    model_label: String,
    rating: String,
    issue: String,
    note: String,
    with_example: bool,
    #[serde(default)]
    training_permission: bool,
    delete_hash: String,
    before_sha256: Option<String>,
    after_sha256: Option<String>,
}
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn hash(bytes: &[u8]) -> String { hex::encode(Sha256::digest(bytes)) }
fn authed(headers: &HeaderMap, token: &str) -> bool {
    let h = headers.get(axum::http::header::AUTHORIZATION).and_then(|x| x.to_str().ok()).unwrap_or("");
    let candidate = h.strip_prefix("Bearer ").unwrap_or("");
    candidate.len() == token.len() && candidate.as_bytes().ct_eq(token.as_bytes()).into()
}
async fn allow_rate(state: &AppState) -> bool {
    let mut recent = state.rate.lock().await;
    recent.retain(|t| t.elapsed() < Duration::from_secs(60));
    if recent.len() >= 30 { return false; }
    recent.push(Instant::now());
    true
}
fn valid_label(s: &str, max: usize) -> bool {
    s.len() <= max && !s.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
}
fn scrub_png(data_b64: &str) -> ApiResult<Vec<u8>> {
    if data_b64.len() > (MAX_PNG_BYTES * 4 / 3 + 8) { return Err(bad("Image too large")); }
    let data = BASE64.decode(data_b64).map_err(|_| bad("Invalid image encoding"))?;
    if data.len() > MAX_PNG_BYTES { return Err(bad("Image too large")); }
    // Validate signature + IHDR before decoding; avoids decompression bombs.
    if data.len() < 24 || &data[..8] != b"\x89PNG\r\n\x1a\n" || &data[12..16] != b"IHDR" {
        return Err(bad("Only PNG previews allowed"));
    }
    let w = u32::from_be_bytes(data[16..20].try_into().unwrap());
    let h = u32::from_be_bytes(data[20..24].try_into().unwrap());
    if w == 0 || h == 0 || w > 720 || h > 720 { return Err(bad("Preview may be at most 720x720")); }
    let rgb = image::load_from_memory_with_format(&data, image::ImageFormat::Png)
        .map_err(|_| bad("Image cannot be decoded"))?.to_rgb8();
    let mut sanitized = std::io::Cursor::new(Vec::<u8>::new());
    image::DynamicImage::ImageRgb8(rgb).write_to(&mut sanitized, image::ImageFormat::Png)
        .map_err(|_| bad("Image cannot be re-encoded"))?;
    Ok(sanitized.into_inner())
}

async fn submit(State(state): State<AppState>, headers: HeaderMap, Json(c): Json<Contribution>) -> ApiResult<(StatusCode, Json<Receipt>)> {
    if !authed(&headers, &state.token) { return Err((StatusCode::UNAUTHORIZED, "Beta token required".into())); }
    if !allow_rate(&state).await { return Err((StatusCode::TOO_MANY_REQUESTS, "Too many requests".into())); }
    if c.consent_version != CONSENT && c.consent_version != LEGACY_CONSENT { return Err(bad("Consent version not accepted")); }
    if c.training_permission && c.consent_version != CONSENT { return Err(bad("Training grant requires updated consent")); }
    if !valid_label(&c.model_label, 100) || !valid_label(&c.note, 400) || !valid_label(&c.app_version, 50) { return Err(bad("Invalid metadata length")); }
    if !["Good", "Needs work", "Unusable"].contains(&c.rating.as_str()) { return Err(bad("Invalid rating")); }
    if !["Detail retained", "Lettering damaged", "Over-smoothed", "Colour artifacts", "Halos", "Noise remains", "Invented texture"].contains(&c.issue.as_str()) { return Err(bad("Invalid issue")); }
    let (before, after) = match (&c.before_png_b64, &c.after_png_b64) {
        (None, None) => (None, None),
        (Some(a), Some(b)) => (Some(scrub_png(a)?), Some(scrub_png(b)?)),
        _ => return Err(bad("Before and after previews must be submitted together")),
    };
    if c.training_permission && before.is_none() { return Err(bad("Training permission requires expressly approved image examples")); }
    let id = Uuid::new_v4().to_string();
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).map_err(|_| internal())?;
    let secret_hex = hex::encode(secret);
    let dir = state.data_dir.join(&id);
    tokio::fs::create_dir(&dir).await.map_err(|_| internal())?;
    let created = now();
    let meta = StoredMeta {
        id: id.clone(), created_unix: created, expires_unix: created + RETAIN_SECS,
        consent_version: c.consent_version, app_version: c.app_version,
        model_label: c.model_label, rating: c.rating, issue: c.issue, note: c.note,
        with_example: before.is_some(), training_permission: c.training_permission, delete_hash: hash(secret_hex.as_bytes()),
        before_sha256: before.as_ref().map(|b| hash(b)),
        after_sha256: after.as_ref().map(|b| hash(b)),
    };
    let saved: Result<()> = async {
        if let Some(b) = before { tokio::fs::write(dir.join("before.png"), b).await?; }
        if let Some(a) = after { tokio::fs::write(dir.join("after.png"), a).await?; }
        tokio::fs::write(dir.join("metadata.json"), serde_json::to_vec_pretty(&meta)?).await?;
        Ok(())
    }.await;
    if saved.is_err() { let _ = tokio::fs::remove_dir_all(&dir).await; return Err(internal()); }
    Ok((StatusCode::CREATED, Json(Receipt { id, deletion_secret: secret_hex })))
}
async fn remove(State(state): State<AppState>, Path(id): Path<String>, headers: HeaderMap) -> ApiResult<StatusCode> {
    if !authed(&headers, &state.token) { return Err((StatusCode::UNAUTHORIZED, "Beta token required".into())); }
    // Canonical UUID constrains path segments; prevents path traversal.
    let parsed = Uuid::parse_str(&id).map_err(|_| bad("Invalid receipt id"))?;
    if parsed.to_string() != id { return Err(bad("Invalid receipt id")); }
    let secret = headers.get("X-Delete-Token").and_then(|v| v.to_str().ok()).unwrap_or("");
    let data = tokio::fs::read(state.data_dir.join(&id).join("metadata.json"))
        .await.map_err(|_| (StatusCode::NOT_FOUND, "Receipt not found".into()))?;
    let meta: StoredMeta = serde_json::from_slice(&data).map_err(|_| internal())?;
    let provided = hash(secret.as_bytes());
    if provided.as_bytes().ct_eq(meta.delete_hash.as_bytes()).unwrap_u8() != 1 {
        return Err((StatusCode::FORBIDDEN, "Incorrect deletion secret".into()));
    }
    tokio::fs::remove_dir_all(state.data_dir.join(&id)).await.map_err(|_| internal())?;
    Ok(StatusCode::NO_CONTENT)
}
async fn health() -> &'static str { "aeroenhance-feedback-beta-ok" }
async fn cleanup(dir: &FsPath) -> Result<usize> {
    let mut entries = tokio::fs::read_dir(dir).await?;
    let mut removed = 0;
    while let Some(entry) = entries.next_entry().await? {
        let path = entry.path();
        if !path.is_dir() { continue; }
        let Ok(b) = tokio::fs::read(path.join("metadata.json")).await else { continue; };
        let Ok(meta) = serde_json::from_slice::<StoredMeta>(&b) else { continue; };
        if meta.expires_unix <= now() && tokio::fs::remove_dir_all(&path).await.is_ok() { removed += 1; }
    }
    Ok(removed)
}
#[tokio::main]
async fn main() -> Result<()> {
    // Fail closed without explicit operator configuration.
    let token = std::env::var("AERO_BETA_TOKEN").context("Set AERO_BETA_TOKEN (random 32+ characters) before starting")?;
    anyhow::ensure!(token.len() >= 32, "AERO_BETA_TOKEN must be at least 32 characters");
    let dir = PathBuf::from(std::env::var("AERO_FEEDBACK_DIR").unwrap_or_else(|_| "./private-feedback".into()));
    tokio::fs::create_dir_all(&dir).await?;
    let state = AppState { token: Arc::new(token), data_dir: Arc::new(dir.clone()), rate: Arc::new(Mutex::new(Vec::new())) };
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/contributions", post(submit))
        .route("/v1/contributions/{id}", delete(remove))
        .layer(DefaultBodyLimit::max(MAX_BYTES))
        .with_state(state);
    tokio::spawn(async move {
        let mut clock = tokio::time::interval(Duration::from_secs(24*3600));
        loop { clock.tick().await; let _ = cleanup(&dir).await; }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8787").await?;
    println!("Private beta feedback server listening on 127.0.0.1:8787 only");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unauthorized_without_beta_token() {
        assert!(!authed(&HeaderMap::new(), "abcdefghijklmnopqrstuvwxyz012345"));
    }
    #[test]
    fn rejects_invalid_png() {
        assert!(scrub_png(&BASE64.encode(b"hello")).is_err());
    }
}
