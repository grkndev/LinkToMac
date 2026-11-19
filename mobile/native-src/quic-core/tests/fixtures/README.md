# Test fixtures

`mac-cert.der` and `mac-cert.sha256` are a sample QUIC server certificate written by the **Mac's** hand-rolled DER
encoder, and the SHA-256 fingerprint the Mac (CryptoKit) computes for it. `tests/mac_cert.rs` proves Rust can parse
what the Mac writes, verify its self-signature, and compute the same fingerprint.

The certificate comes from a throwaway in-memory key (nothing is stored in any Keychain), so a regeneration produces
different bytes; the test only checks structure and that the two files agree, not exact values.

Regenerate from `mac/`:

```sh
swiftc -O Sources/LinkToMac/Quic/DERWriter.swift Sources/LinkToMac/Quic/QuicIdentity.swift \
       scripts/gen-quic-cert-fixture/main.swift -o /tmp/gen-quic-cert-fixture
/tmp/gen-quic-cert-fixture ../mobile/native-src/quic-core/tests/fixtures/mac-cert.der \
                           ../mobile/native-src/quic-core/tests/fixtures/mac-cert.sha256
```

Independent cross-check (neither the Mac code nor the Rust test): `openssl x509 -inform DER -in mac-cert.der -noout -text`
(v3, `CN=LinkToMac`, `ecdsa-with-SHA256`, `prime256v1`) and `openssl verify` on the PEM form.
