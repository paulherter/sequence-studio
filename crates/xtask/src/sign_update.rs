// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask sign-update <file>...` and `cargo xtask update-keygen`: the ed25519 signature of release files.
//!
//! The signature is over the 32-byte SHA-256 of the file and is written as 128 lowercase hex characters plus a newline to
//! `<file>.sig`. The private key (32-byte seed, hex) is a generic password item `sq-update-signing` in the macOS login
//! keychain; `update-keygen` creates it once and prints only the public key (hex) for the app to embed. The `SQ_UPDATE_SEED`
//! environment variable (hex) replaces the keychain for tests.

use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

const SERVICE: &str = "sq-update-signing";
const ACCOUNT: &str = "sq-update";

pub(crate) fn run_sign(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("usage: cargo xtask sign-update <file>...".into());
    }
    let key = load_key()?;
    for f in args {
        let path = Path::new(f);
        let sig = sign_file(&key, path)?;
        let out = sig_path(path);
        std::fs::write(&out, format!("{sig}\n")).map_err(|e| format!("{}: {e}", out.display()))?;
        println!("signed {}", out.display());
    }
    Ok(())
}

pub(crate) fn run_keygen() -> Result<(), String> {
    if keychain_seed().is_ok() {
        return Err(format!("keychain item {SERVICE} exists already; refusing to replace the signing key"));
    }
    let mut seed = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut seed))
        .map_err(|e| format!("random seed: {e}"))?;
    let key = SigningKey::from_bytes(&seed);
    let st = Command::new("security")
        .args(["add-generic-password", "-a", ACCOUNT, "-s", SERVICE, "-w", &hex(&seed)])
        .status()
        .map_err(|e| format!("security: {e}"))?;
    if !st.success() {
        return Err(format!("could not store the key in the keychain ({st})"));
    }
    println!("{}", hex(key.verifying_key().as_bytes()));
    Ok(())
}

fn sig_path(file: &Path) -> PathBuf {
    let mut s = file.as_os_str().to_owned();
    s.push(".sig");
    PathBuf::from(s)
}

fn keychain_seed() -> Result<String, String> {
    let o = Command::new("security")
        .args(["find-generic-password", "-s", SERVICE, "-w"])
        .output()
        .map_err(|e| format!("security: {e}"))?;
    if !o.status.success() {
        return Err(format!("no keychain item {SERVICE} (run cargo xtask update-keygen once)"));
    }
    Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
}

fn load_key() -> Result<SigningKey, String> {
    let seed = match std::env::var("SQ_UPDATE_SEED") {
        Ok(s) if !s.is_empty() => s,
        _ => keychain_seed()?,
    };
    let bytes = unhex(&seed).ok_or("the signing key is not 64 hex characters")?;
    let arr: [u8; 32] = bytes.try_into().map_err(|_| "the signing key is not 32 bytes")?;
    Ok(SigningKey::from_bytes(&arr))
}

fn sha256_file(path: &Path) -> Result<[u8; 32], String> {
    let mut f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().into())
}

fn sign_file(key: &SigningKey, path: &Path) -> Result<String, String> {
    let digest = sha256_file(path)?;
    Ok(hex(&key.sign(&digest).to_bytes()))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    fn verify_hex(public: &VerifyingKey, digest: &[u8; 32], sig_hex: &str) -> bool {
        let Some(bytes) = unhex(sig_hex.trim()) else { return false };
        let Ok(arr) = <[u8; 64]>::try_from(bytes) else { return false };
        public.verify(digest, &Signature::from_bytes(&arr)).is_ok()
    }

    #[test]
    fn signature_verifies_and_rejects_a_changed_file() {
        let dir = std::env::temp_dir().join(format!("sq-sign-update-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.bin");
        std::fs::write(&file, b"release bytes").unwrap();
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let sig = sign_file(&key, &file).unwrap();
        assert_eq!(sig.len(), 128);
        let public = key.verifying_key();
        assert!(verify_hex(&public, &sha256_file(&file).unwrap(), &sig));
        std::fs::write(&file, b"changed").unwrap();
        assert!(!verify_hex(&public, &sha256_file(&file).unwrap(), &sig));
        assert!(!verify_hex(&public, &[0u8; 32], "zz"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn hex_round_trip_and_sig_path() {
        assert_eq!(unhex(&hex(&[0, 15, 255])), Some(vec![0, 15, 255]));
        assert_eq!(unhex("abc"), None);
        assert_eq!(sig_path(Path::new("/o/x.dmg")), PathBuf::from("/o/x.dmg.sig"));
    }
}
