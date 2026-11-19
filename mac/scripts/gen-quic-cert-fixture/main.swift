// Writes a sample QUIC server certificate (built from a throwaway in-memory key) and its SHA-256 fingerprint,
// the fixtures for the Rust cross-check (mobile/native-src/quic-core/tests/mac_cert.rs): Rust must parse a
// certificate the Mac wrote, verify its signature, and compute the same fingerprint as CryptoKit.
//
//   swiftc -O Sources/LinkToMac/Quic/DERWriter.swift Sources/LinkToMac/Quic/QuicIdentity.swift \
//          scripts/gen-quic-cert-fixture/main.swift -o /tmp/gen-quic-cert-fixture
//   /tmp/gen-quic-cert-fixture ../mobile/native-src/quic-core/tests/fixtures/mac-cert.der \
//                              ../mobile/native-src/quic-core/tests/fixtures/mac-cert.sha256
//
// (run from mac/). The key is NOT stored anywhere: nothing here touches the Keychain.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: gen-quic-cert-fixture <out.der> <out.sha256>\n".utf8))
    exit(2)
}

do {
    let key = try QuicIdentity.makeEphemeralKey()
    let der = try QuicIdentity.certificate(for: key)
    try der.write(to: URL(fileURLWithPath: arguments[1]))
    let fingerprint = QuicIdentity.fingerprint(of: der)
    try (fingerprint + "\n").write(toFile: arguments[2], atomically: true, encoding: .utf8)
    print("wrote \(der.count) bytes, sha256 \(fingerprint)")
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
