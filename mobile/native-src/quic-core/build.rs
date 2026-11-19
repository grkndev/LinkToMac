// Exposes the resolved quinn version (from Cargo.lock) to the crate as QUIC_CORE_QUINN_VERSION,
// so `ping()` can report which quinn the .so was actually built against.
use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    let lock = fs::read_to_string(Path::new(&manifest_dir).join("Cargo.lock")).unwrap_or_default();

    let mut version = String::from("unknown");
    let mut lines = lock.lines();
    while let Some(line) = lines.next() {
        if line.trim() == "name = \"quinn\"" {
            if let Some(next) = lines.next() {
                if let Some(v) = next.trim().strip_prefix("version = \"") {
                    version = v.trim_end_matches('"').to_string();
                }
            }
            break;
        }
    }
    println!("cargo:rustc-env=QUIC_CORE_QUINN_VERSION={version}");
}
