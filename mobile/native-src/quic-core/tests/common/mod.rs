//! A client and a server connection over loopback, for tests that need real quinn streams (no token protocol: the file stream sits on top
//! of an already open connection). Dev only.
#![allow(dead_code)]

use std::sync::Arc;

use quic_core::pin::{client_config, fingerprint, ALPN, SERVER_NAME};

pub struct Pair {
    pub client: quinn::Connection,
    pub server: quinn::Connection,
    // The endpoints must outlive the connections.
    _client_endpoint: quinn::Endpoint,
    _server_endpoint: quinn::Endpoint,
}

pub async fn loopback() -> Pair {
    let generated = rcgen::generate_simple_self_signed(vec![SERVER_NAME.to_string()]).unwrap();
    let cert_der = generated.cert.der().clone();
    let fp = fingerprint(cert_der.as_ref());
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key.into())
        .unwrap();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let quic = quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap();
    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic));
    // Plenty of room for many streams in a test.
    let mut transport = quinn::TransportConfig::default();
    transport.max_concurrent_bidi_streams(64u32.into());
    server_config.transport_config(Arc::new(transport));

    let server_endpoint = quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = server_endpoint.local_addr().unwrap();
    let mut client_endpoint = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    client_endpoint.set_default_client_config(client_config(&fp).unwrap());

    let connecting = client_endpoint.connect(addr, SERVER_NAME).unwrap();
    let (client, server) = tokio::join!(connecting, async { server_endpoint.accept().await.unwrap().await });
    Pair { client: client.unwrap(), server: server.unwrap(), _client_endpoint: client_endpoint, _server_endpoint: server_endpoint }
}
