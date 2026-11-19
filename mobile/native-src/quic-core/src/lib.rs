//! quic-core: the Link To Mac QUIC data-plane core for the Android `selfadb` module.
//!
//! Stage 0.1 only proves the build chain (cargo-ndk -> libquic_core.so -> JNI): `ping()` says the
//! library loads and is callable, `probe()` additionally exercises quinn + rustls (ring) + tokio on
//! the device by building a TLS 1.3 client config and binding (then closing) a UDP endpoint. No
//! network traffic leaves the device and no address, port or key ever appears in a result string.

pub mod pin;

use std::net::Ipv4Addr;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use jni::objects::JClass;
use jni::sys::jstring;
use jni::JNIEnv;

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const QUINN_VERSION: &str = env!("QUIC_CORE_QUINN_VERSION");

/// Proves the library is loaded and callable. Reports the versions it was built with.
pub fn ping() -> String {
    format!("pong quic-core {CORE_VERSION} quinn {QUINN_VERSION}")
}

/// Proves quinn + rustls (ring) + tokio work at runtime: builds a TLS 1.3 QUIC client config, binds a
/// UDP endpoint on an ephemeral port, then closes it. Error strings are static (no addresses/ports).
pub fn probe() -> Result<String, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| "tls: protocol versions".to_string())?
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
    let quic_tls = quinn::crypto::rustls::QuicClientConfig::try_from(tls)
        .map_err(|_| "tls: quic client config".to_string())?;
    let client_config = quinn::ClientConfig::new(Arc::new(quic_tls));

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| "runtime: build".to_string())?;

    runtime.block_on(async {
        let mut endpoint = quinn::Endpoint::client((Ipv4Addr::UNSPECIFIED, 0).into())
            .map_err(|_| "udp: bind".to_string())?;
        endpoint.set_default_client_config(client_config);
        endpoint.local_addr().map_err(|_| "udp: local addr".to_string())?;
        endpoint.close(0u32.into(), b"probe");
        endpoint.wait_idle().await;
        Ok::<(), String>(())
    })?;

    Ok("probe ok".to_string())
}

fn to_jstring(env: &mut JNIEnv, value: &str) -> jstring {
    env.new_string(value).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// JNI: `QuicCore.nativePing()`. A panic becomes an error string instead of unwinding into the JVM.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativePing(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let out = catch_unwind(AssertUnwindSafe(ping)).unwrap_or_else(|_| "error: panic".to_string());
    to_jstring(&mut env, &out)
}

/// JNI: `QuicCore.nativeProbe()`. Returns "probe ok" or "error: <static reason>".
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeProbe(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let out = match catch_unwind(AssertUnwindSafe(probe)) {
        Ok(Ok(ok)) => ok,
        Ok(Err(reason)) => format!("error: {reason}"),
        Err(_) => "error: panic".to_string(),
    };
    to_jstring(&mut env, &out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_reports_both_versions() {
        let s = ping();
        assert!(s.starts_with("pong quic-core "), "unexpected ping: {s}");
        assert!(s.contains(CORE_VERSION));
        assert!(!QUINN_VERSION.is_empty());
        assert_ne!(QUINN_VERSION, "unknown", "build.rs could not read the quinn version from Cargo.lock");
        assert!(s.contains(QUINN_VERSION));
    }

    #[test]
    fn probe_binds_and_closes_an_endpoint() {
        assert_eq!(probe().as_deref(), Ok("probe ok"));
    }

    #[test]
    fn probe_is_repeatable() {
        // A second run must not fail on leftover state (fresh runtime + fresh ephemeral port each time).
        assert_eq!(probe().as_deref(), Ok("probe ok"));
        assert_eq!(probe().as_deref(), Ok("probe ok"));
    }
}
