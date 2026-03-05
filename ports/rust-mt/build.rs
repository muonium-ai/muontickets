use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn tool_version(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    }
}

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set"));
    let version_path = manifest_dir.join("../../VERSION");

    println!("cargo:rerun-if-changed={}", version_path.display());

    let version_raw = fs::read_to_string(&version_path)
        .unwrap_or_else(|e| panic!("failed to read root VERSION file at {}: {e}", version_path.display()));
    let version_trimmed = version_raw.trim();

    let is_valid = {
        let mut parts = version_trimmed.split('.');
        match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some(major), Some(minor), None, None) => {
                !major.is_empty()
                    && !minor.is_empty()
                    && major.chars().all(|c| c.is_ascii_digit())
                    && minor.chars().all(|c| c.is_ascii_digit())
            }
            (Some(major), Some(minor), Some(patch), None) => {
                !major.is_empty()
                    && !minor.is_empty()
                    && !patch.is_empty()
                    && major.chars().all(|c| c.is_ascii_digit())
                    && minor.chars().all(|c| c.is_ascii_digit())
                    && patch.chars().all(|c| c.is_ascii_digit())
            }
            _ => false,
        }
    };

    if !is_valid {
        panic!("invalid VERSION format '{}'; expected '<major>.<minor>[.<patch>]'", version_trimmed);
    }

    println!("cargo:rustc-env=MT_ROOT_VERSION={}", version_trimmed);
    println!("cargo:rustc-env=MT_RUSTC_VERSION={}", tool_version("rustc", &["--version"]));
    println!("cargo:rustc-env=MT_CARGO_VERSION={}", tool_version("cargo", &["--version"]));
}
