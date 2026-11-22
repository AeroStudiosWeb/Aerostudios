//! Opt-in private-beta updates and contributions.
//! No background telemetry, no photographs sent during update checks.
use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs::{self, File}, io::{Read, Write}, path::{Path, PathBuf}, time::{Duration, SystemTime, UNIX_EPOCH}};

pub const DEFAULT_MANIFEST_URL: &str = "https://aerostudiosweb.github.io/AeroStudios/aeroenhance/updates/beta.signed.json";
pub const DEFAULT_FEEDBACK_URL: &str = "http://127.0.0.1:8787/v1/contributions";
pub const CONSENT_VERSION: &str = "2026-11-beta-v2-training";
const MAX_MANIFEST: usize = 64 * 1024;
const MAX_MODEL: u64 = 3 * 1024 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub check_updates_at_launch: bool,
    pub auto_install_models: bool,
    pub contribute_enabled: bool,
    pub manifest_url: String,
    pub feedback_url: String,
    pub active_model_path: String,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            check_updates_at_launch: false,
            auto_install_models: false,
            contribute_enabled: false,
            manifest_url: DEFAULT_MANIFEST_URL.into(),
            feedback_url: DEFAULT_FEEDBACK_URL.into(),
            active_model_path: String::new(),
        }
    }
}
fn config_dir() -> Result<PathBuf> {
    let base = std::env::var_os("APPDATA")
        .or_else(|| std::env::var_os("XDG_CONFIG_HOME"))
        .or_else(|| std::env::var_os("HOME"))
        .context("Cannot find local configuration directory")?;
    Ok(PathBuf::from(base).join("AeroStudios").join("AeroEnhance"))
}
pub fn model_dir() -> Result<PathBuf> { Ok(config_dir()?.join("models")) }
pub fn load_preferences() -> Preferences {
    config_dir().ok().and_then(|d| fs::read(d.join("preferences.json")).ok())
        .and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}
pub fn save_preferences(p: &Preferences) -> Result<()> {
    let d = config_dir()?;
    fs::create_dir_all(&d)?;
    let temp = d.join("preferences.json.tmp");
    fs::write(&temp, serde_json::to_vec_pretty(p)?)?;
    // On Windows rename doesn't replace an existing destination. This file is
    // only a local preference, not a security decision.
    if d.join("preferences.json").exists() { fs::remove_file(d.join("preferences.json"))?; }
    fs::rename(temp, d.join("preferences.json"))?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelManifest {
    pub schema: u32,
    pub channel: String,
    pub model_id: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub size_bytes: u64,
    pub sha256: String,
    pub min_app_version: String,
    pub expires_unix: u64,
    pub notes: String,
    pub latest_app_version: Option<String>,
    pub app_release_url: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedManifest {
    pub payload_b64: String,
    pub signature_b64: String,
}

pub fn verify_manifest(bytes: &[u8], pubkey_hex: &str, now: u64) -> Result<ModelManifest> {
    if bytes.len() > MAX_MANIFEST { bail!("Update manifest too large"); }
    let envelope: SignedManifest = serde_json::from_slice(bytes).context("Invalid signed update JSON")?;
    let msg = BASE64.decode(&envelope.payload_b64).context("Invalid manifest encoding")?;
    if msg.len() > MAX_MANIFEST { bail!("Signed manifest payload too large"); }
    let key: [u8; 32] = hex::decode(pubkey_hex).context("Invalid pinned update public key")?
        .try_into().map_err(|_| anyhow!("Ed25519 public key must be 32 bytes"))?;
    let signature: [u8; 64] = BASE64.decode(&envelope.signature_b64)
        .context("Invalid signature encoding")?.try_into().map_err(|_| anyhow!("Bad signature length"))?;
    VerifyingKey::from_bytes(&key)?.verify_strict(&msg, &Signature::from_bytes(&signature))
        .context("Update signature not trusted — download refused")?;
    let m: ModelManifest = serde_json::from_slice(&msg).context("Invalid signed model metadata")?;
    if m.schema != 1 || m.channel != "beta" { bail!("Unexpected update schema or channel"); }
    if m.expires_unix <= now { bail!("Update manifest expired — download refused"); }
    if m.size_bytes == 0 || m.size_bytes > MAX_MODEL { bail!("Invalid model size"); }
    if m.sha256.len() != 64 || !m.sha256.bytes().all(|b| b.is_ascii_hexdigit()) { bail!("Invalid model hash"); }
    for segment in [&m.model_id, &m.version, &m.file_name] {
        if segment.is_empty() || segment.len() > 100 || !segment.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
            || segment == "." || segment == ".." { bail!("Invalid model path segment"); }
    }
    if !m.file_name.ends_with(".onnx") { bail!("Only ONNX model files are supported"); }
    semver::Version::parse(&m.version).context("Invalid model version")?;
    let app_min = semver::Version::parse(&m.min_app_version).context("Invalid min app version")?;
    let current = semver::Version::parse(env!("CARGO_PKG_VERSION"))?;
    if app_min > current { bail!("This model requires AeroEnhance {app_min} or newer"); }
    validate_url(&m.url)?;
    if let Some(url) = &m.app_release_url { validate_url(url)?; }
    Ok(m)
}

fn validate_url(url: &str) -> Result<()> {
    let u = url::Url::parse(url).context("Invalid URL")?;
    // For local beta testing a loopback-only server is allowed. Never use
    // arbitrary plaintext remote endpoints.
    if u.scheme() == "https" { return Ok(()); }
    if u.scheme() == "http" && matches!(u.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")) { return Ok(()); }
    bail!("HTTPS required (HTTP is allowed only on localhost)")
}
fn client() -> Result<Client> {
    Ok(Client::builder().timeout(Duration::from_secs(120))
        .connect_timeout(Duration::from_secs(10))
        .user_agent(concat!("AeroEnhance/", env!("CARGO_PKG_VERSION")))
        .build()?)
}
fn bounded_get(url: &str, max: usize) -> Result<Vec<u8>> {
    validate_url(url)?;
    let mut r = client()?.get(url).send()?.error_for_status()?;
    if r.content_length().is_some_and(|len| len > max as u64) { bail!("Server response exceeded size limit"); }
    let mut buf = Vec::new();
    (&mut r).take((max + 1) as u64).read_to_end(&mut buf)?;
    if buf.len() > max { bail!("Response exceeded size limit"); }
    Ok(buf)
}
pub fn check_updates(url: &str) -> Result<ModelManifest> {
    // This is a compile-time trust anchor, not a key supplied by the server.
    let pubkey = option_env!("AERO_UPDATE_PUBLIC_KEY_HEX")
        .filter(|v| !v.is_empty()).context("No publisher update public key compiled in. Set AERO_UPDATE_PUBLIC_KEY_HEX and rebuild.")?;
    let raw = bounded_get(url, MAX_MANIFEST)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    verify_manifest(&raw, pubkey, now)
}
pub fn install_model(m: &ModelManifest) -> Result<PathBuf> {
    // Revalidate values in case code calls this with a locally constructed struct.
    validate_url(&m.url)?;
    let target_dir = model_dir()?.join(&m.model_id).join(&m.version);
    fs::create_dir_all(&target_dir)?;
    let dest = target_dir.join(&m.file_name);
    if dest.is_file() {
        let hash = sha_file(&dest)?;
        if hash.eq_ignore_ascii_case(&m.sha256) { return Ok(dest); }
        bail!("Existing model file has a different checksum. Move it aside manually before retrying.");
    }
    let temp = target_dir.join(format!(".{}.{}.part", &m.file_name, std::process::id()));
    let outcome: Result<()> = (|| {
        let mut stream = client()?.get(&m.url).send()?.error_for_status()?;
        if stream.content_length().is_some_and(|len| len != m.size_bytes) { bail!("Model Content-Length differs from signed manifest"); }
        let mut f = File::create(&temp)?;
        let mut hash = Sha256::new();
        let mut seen = 0u64;
        let mut buf = [0u8; 128 * 1024];
        loop {
            let n = stream.read(&mut buf)?;
            if n == 0 { break; }
            seen += n as u64;
            if seen > m.size_bytes { bail!("Model download larger than signed size"); }
            f.write_all(&buf[..n])?;
            hash.update(&buf[..n]);
        }
        f.sync_all()?;
        if seen != m.size_bytes { bail!("Incomplete model download"); }
        if hex::encode(hash.finalize()) != m.sha256.to_lowercase() { bail!("Model SHA-256 mismatch — update rejected"); }
        fs::rename(&temp, &dest).context("Unable to activate verified model")?;
        Ok(())
    })();
    if outcome.is_err() { let _ = fs::remove_file(&temp); }
    outcome?;
    Ok(dest)
}
fn sha_file(p: &Path) -> Result<String> {
    let mut f = File::open(p)?;
    let mut hash = Sha256::new();
    let mut buf = [0u8; 128*1024];
    loop { let n = f.read(&mut buf)?; if n == 0 { break; } hash.update(&buf[..n]); }
    Ok(hex::encode(hash.finalize()))
}

#[derive(Debug, Clone, Serialize)]
pub struct Contribution {
    pub consent_version: String,
    pub app_version: String,
    pub model_label: String,
    pub rating: String,
    pub issue: String,
    pub note: String,
    pub before_png_b64: Option<String>,
    pub after_png_b64: Option<String>,
    /// Separate, explicit license to use approved image previews for research/training.
    /// Not a statement that either image is a clean target.
    pub training_permission: bool,
}
#[derive(Debug, Clone, Deserialize)]
pub struct Receipt { pub id: String, pub deletion_secret: String }
pub fn send_contribution(url: &str, beta_token: &str, payload: &Contribution) -> Result<Receipt> {
    validate_url(url)?;
    if beta_token.len() < 16 { bail!("Private beta access token is missing or too short"); }
    if payload.consent_version != CONSENT_VERSION { bail!("Outdated consent version"); }
    let resp = client()?.post(url)
        .bearer_auth(beta_token)
        .json(payload).send()?.error_for_status()?.json::<Receipt>()?;
    Ok(resp)
}
pub fn delete_contribution(url: &str, beta_token: &str, receipt: &Receipt) -> Result<()> {
    validate_url(url)?;
    let root = url.trim_end_matches('/');
    let endpoint = format!("{root}/{}", receipt.id);
    client()?.delete(&endpoint).bearer_auth(beta_token)
        .header("X-Delete-Token", &receipt.deletion_secret)
        .send()?.error_for_status()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn no_network_by_default() {
        let p = Preferences::default();
        assert!(!p.check_updates_at_launch);
        assert!(!p.auto_install_models);
        assert!(!p.contribute_enabled);
    }
    #[test]
    fn insecure_remote_url_is_rejected() {
        assert!(validate_url("http://example.com/file.onnx").is_err());
        assert!(validate_url("http://127.0.0.1:8787/test").is_ok());
        assert!(validate_url("https://github.com/x").is_ok());
    }
    #[test]
    fn accepts_known_signed_fixture_and_rejects_expiry() {
        let json = include_bytes!("../tests/fixture-signed-manifest.json");
        let pubkey = include_str!("../tests/fixture-public-key.txt").trim();
        let checked = verify_manifest(json, pubkey, 1800000000).unwrap();
        assert_eq!(checked.model_id, "aero-denoise-test");
        assert!(verify_manifest(json, pubkey, 4102444800).is_err());
    }
    #[test]
    fn rejects_payload_tampering_even_if_json_valid() {
        let raw = include_bytes!("../tests/fixture-signed-manifest.json");
        let pubkey = include_str!("../tests/fixture-public-key.txt").trim();
        let mut envelope: SignedManifest = serde_json::from_slice(raw).unwrap();
        let mut msg = BASE64.decode(&envelope.payload_b64).unwrap();
        let at = msg.windows(b"aero-denoise-test".len()).position(|w| w == b"aero-denoise-test").unwrap();
        msg[at] = b'X';
        envelope.payload_b64 = BASE64.encode(&msg);
        let changed = serde_json::to_vec(&envelope).unwrap();
        assert!(verify_manifest(&changed, pubkey, 1800000000).is_err());
    }
    #[test]
    fn manifest_rejects_missing_signature() {
        let invalid = br#"{"payload_b64":"e30=","signature_b64":"AAAA"}"#;
        assert!(verify_manifest(invalid, &"00".repeat(32), 1).is_err());
    }
}
