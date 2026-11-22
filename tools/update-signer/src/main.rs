//! Offline manifest signer. NEVER commit the private key to GitHub.
use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::{Signer, SigningKey, Signature, VerifyingKey};
use std::{env, fs, path::Path};

fn read_hex(path: &str) -> Result<[u8;32]> {
    let raw = fs::read_to_string(path)?;
    Ok(hex::decode(raw.trim())?.try_into().map_err(|_| anyhow::anyhow!("Expected 32-byte hex key"))?)
}
fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    match args.as_slice() {
        [_, cmd, output_secret] if cmd == "keygen" => {
            if Path::new(output_secret).exists() { bail!("Secret key already exists; refusing to overwrite"); }
            let mut secret = [0u8;32];
            getrandom::fill(&mut secret)?;
            let signer = SigningKey::from_bytes(&secret);
            fs::write(output_secret, format!("{}\n", hex::encode(secret)))?;
            let pubfile = format!("{output_secret}.pub");
            fs::write(&pubfile, format!("{}\n", hex::encode(signer.verifying_key().to_bytes())))?;
            println!("PRIVATE SIGNING KEY: {output_secret} (keep offline, never commit)");
            println!("PUBLIC VERIFICATION KEY: {pubfile} (safe to use at build time)");
        }
        [_, cmd, private_key, manifest_json, signed_output] if cmd == "sign" => {
            let signer = SigningKey::from_bytes(&read_hex(private_key)?);
            let msg = fs::read(manifest_json).with_context(|| format!("Unable to read {manifest_json}"))?;
            let _: serde_json::Value = serde_json::from_slice(&msg)?;
            let signature = signer.sign(&msg);
            let envelope = serde_json::json!({
                "payload_b64": BASE64.encode(&msg),
                "signature_b64": BASE64.encode(signature.to_bytes()),
            });
            fs::write(signed_output, serde_json::to_vec_pretty(&envelope)?)?;
            println!("Signed exact manifest bytes: {signed_output}");
        }
        [_, cmd, public_key, signed_file] if cmd == "verify" => {
            let key = VerifyingKey::from_bytes(&read_hex(public_key)?)?;
            let env: serde_json::Value = serde_json::from_slice(&fs::read(signed_file)?)?;
            let msg = BASE64.decode(env["payload_b64"].as_str().context("Missing payload")?)?;
            let sig: [u8;64] = BASE64.decode(env["signature_b64"].as_str().context("Missing signature")?)?
                .try_into().map_err(|_| anyhow::anyhow!("Invalid signature length"))?;
            key.verify_strict(&msg, &Signature::from_bytes(&sig))?;
            println!("Signature valid. Manifest: {}", String::from_utf8_lossy(&msg));
        }
        _ => bail!("Usage:\n  aeroenhance-update-signer keygen SECRET_KEY_PATH\n  aeroenhance-update-signer sign SECRET_KEY_PATH MANIFEST.json SIGNED.json\n  aeroenhance-update-signer verify PUBLIC_KEY_PATH SIGNED.json"),
    }
    Ok(())
}
