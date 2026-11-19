import CryptoKit
import Foundation
import Security
import Testing

/// The certificate half (no Keychain): built from an in-memory key, parsed back by Apple's own Security framework and
/// verified, so an encoding mistake can't hide behind the writer's own reader.
@Suite struct QuicCertificateTests {
    private let fixedNow = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    }()

    private func readTLV(_ data: Data) -> (tag: UInt8, whole: Data, content: Data, rest: Data) {
        let b = [UInt8](data)
        var length = Int(b[1])
        var header = 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            for i in 0 ..< count { length = (length << 8) | Int(b[2 + i]) }
            header = 2 + count
        }
        let end = header + length
        return (b[0], Data(b[0 ..< end]), Data(b[header ..< end]), Data(b[end...]))
    }

    /// Splits a certificate into (tbs, signature) the way a verifier does.
    private func parts(_ der: Data) -> (tbs: Data, signature: Data) {
        let outer = readTLV(der).content
        let tbs = readTLV(outer)
        let algorithm = readTLV(tbs.rest)
        let bits = readTLV(algorithm.rest)
        precondition(bits.tag == 0x03 && bits.content.first == 0x00)
        return (tbs.whole, bits.content.dropFirst())
    }

    private func verify(_ der: Data, signature: Data? = nil) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData), let key = SecCertificateCopyKey(cert) else { return false }
        let p = parts(der)
        return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, p.tbs as CFData, (signature ?? p.signature) as CFData, nil)
    }

    @Test func appleParsesTheCertificateAndItsSubject() throws {
        let key = try QuicIdentity.makeEphemeralKey()
        let der = try QuicIdentity.certificate(for: key, now: fixedNow)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == "LinkToMac")
        // Self-signed: issuer and subject are the same name.
        #expect(SecCertificateCopyNormalizedIssuerSequence(cert) as Data? == SecCertificateCopyNormalizedSubjectSequence(cert) as Data?)
    }

    @Test func signatureVerifiesAndATamperedOneDoesNot() throws {
        let der = try QuicIdentity.certificate(for: try QuicIdentity.makeEphemeralKey(), now: fixedNow)
        #expect(verify(der))

        var bad = Data(parts(der).signature)
        bad[bad.count - 1] ^= 0x01
        #expect(!verify(der, signature: bad))
    }

    @Test func serialIsSixteenPositiveBytesAndDiffersPerCertificate() throws {
        let key = try QuicIdentity.makeEphemeralKey()
        func serial(_ der: Data) throws -> Data {
            let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
            return try #require(SecCertificateCopySerialNumberData(cert, nil) as Data?)
        }
        let a = try serial(try QuicIdentity.certificate(for: key, now: fixedNow))
        let b = try serial(try QuicIdentity.certificate(for: key, now: fixedNow))
        #expect(a.count == 16)
        #expect(a[0] >= 0x40 && a[0] < 0x80)   // positive, non-zero first byte, so no sign pad
        #expect(a != b)
    }

    @Test func validityRunsFromOneDayAgoForTenYears() throws {
        let der = try QuicIdentity.certificate(for: try QuicIdentity.makeEphemeralKey(), now: fixedNow)
        let text = String(decoding: der, as: UTF8.self)
        #expect(text.contains("261113120000Z"))   // now - 1 day
        #expect(text.contains("361114120000Z"))   // now + 10 years
    }

    @Test func fingerprintIsLowercaseHexOfTheDERDigest() throws {
        let der = try QuicIdentity.certificate(for: try QuicIdentity.makeEphemeralKey(), now: fixedNow)
        let fp = QuicIdentity.fingerprint(of: der)
        #expect(fp.count == 64)
        #expect(fp.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(fp == SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
        #expect(fp == QuicIdentity.fingerprint(of: der))   // stable for the same bytes
    }

    @Test func aCryptoKitKeyAlsoProducesAValidCertificate() throws {
        // The writer is key-agnostic: any P-256 source with a DER ECDSA signature works.
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedCertificate.make(
            publicKeyX963: key.publicKey.x963Representation, commonName: "LinkToMac",
            serial: Data(repeating: 0x42, count: 16), notBefore: fixedNow.addingTimeInterval(-86_400), notAfter: fixedNow.addingTimeInterval(86_400)
        ) { try key.signature(for: $0).derRepresentation }
        #expect(verify(der))
    }
}

/// The Keychain half. Every test gets its own key tag AND its own certificate CN (a certificate's Keychain label is its
/// CN, so a unique CN is what isolates certificates), and removes both afterwards: nothing is left in the developer's
/// real login keychain, and nothing touches the real `dev.grkn.LinkToMac/quic-identity` item.
@Suite(.serialized) struct QuicIdentityKeychainTests {
    private struct Slot {
        let label = "dev.grkn.LinkToMac/quic-identity-test-\(UUID().uuidString)"
        let name = "LinkToMac-test-\(UUID().uuidString.prefix(8))"
        func load() -> QuicIdentity? { QuicIdentity.load(label: label) }
        func loadOrCreate() throws -> QuicIdentity { try QuicIdentity.loadOrCreate(label: label, commonName: name) }
        func reset() { QuicIdentity.reset(label: label, commonName: name) }
    }

    private func count(_ query: [String: Any]) -> Int {
        var full = query
        full[kSecReturnAttributes as String] = true
        full[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(full as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [[String: Any]])?.count ?? 0
    }

    /// (certificates named after the slot's CN, private keys carrying the slot's tag)
    private func counts(_ slot: Slot) -> (certificates: Int, keys: Int) {
        (count([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: slot.name]),
         count([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(slot.label.utf8)]))
    }

    @Test func loadNeverCreatesAnythingAndNeverReturnsSomeoneElsesIdentity() {
        let slot = Slot()
        defer { slot.reset() }
        // The login keychain holds other identities (an Apple Development certificate, say). A lookup for a label
        // that was never created must come back empty, not with one of those.
        #expect(slot.load() == nil)
        #expect(counts(slot) == (0, 0))
    }

    @Test func firstCallCreatesAndTheSecondReturnsTheSameIdentity() throws {
        let slot = Slot()
        defer { slot.reset() }

        let first = try slot.loadOrCreate()
        #expect(counts(slot) == (1, 1))

        let second = try slot.loadOrCreate()
        #expect(second.fingerprint == first.fingerprint)
        #expect(second.certificateDER == first.certificateDER)
        #expect(counts(slot) == (1, 1))   // reloaded, not regenerated

        #expect(slot.load()?.fingerprint == first.fingerprint)
    }

    @Test func theIdentityCarriesTheStoredCertificateAndAUsableKey() throws {
        let slot = Slot()
        defer { slot.reset() }
        let id = try slot.loadOrCreate()

        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(id.identity, &certificate) == errSecSuccess)
        let cert = try #require(certificate)
        #expect(SecCertificateCopyData(cert) as Data == id.certificateDER)
        #expect(SecCertificateCopySubjectSummary(cert) as String? == slot.name)

        // The identity's private key signs and the certificate's public key verifies: what a TLS handshake needs.
        var keyRef: SecKey?
        #expect(SecIdentityCopyPrivateKey(id.identity, &keyRef) == errSecSuccess)
        let privateKey = try #require(keyRef)
        let message = Data("quic identity handshake stand-in".utf8)
        let signature = try #require(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?)
        let publicKey = try #require(SecCertificateCopyKey(cert))
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil))
    }

    @Test func fingerprintMatchesTheStoredCertificate() throws {
        let slot = Slot()
        defer { slot.reset() }
        let id = try slot.loadOrCreate()
        #expect(id.fingerprint == QuicIdentity.fingerprint(of: id.certificateDER))
        #expect(id.fingerprint.count == 64)
    }

    @Test func resetRemovesTheCertificateAndTheKey() throws {
        let slot = Slot()
        defer { slot.reset() }
        _ = try slot.loadOrCreate()
        #expect(counts(slot) == (1, 1))

        slot.reset()
        #expect(counts(slot) == (0, 0))
        #expect(slot.load() == nil)
    }

    @Test func resetOfOneIdentityLeavesAnotherUntouched() throws {
        let a = Slot()
        let b = Slot()
        defer { a.reset(); b.reset() }
        let idA = try a.loadOrCreate()
        let idB = try b.loadOrCreate()
        #expect(idA.fingerprint != idB.fingerprint)

        a.reset()
        #expect(counts(a) == (0, 0))
        #expect(counts(b) == (1, 1))
        #expect(b.load()?.fingerprint == idB.fingerprint)
    }

    @Test func aLeftoverKeyWithoutACertificateIsRepaired() throws {
        let slot = Slot()
        defer { slot.reset() }

        // Simulate a run that died after creating the key.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: slot.label,
                kSecAttrApplicationTag as String: Data(slot.label.utf8),
            ] as [String: Any],
        ]
        #expect(SecKeyCreateRandomKey(attributes as CFDictionary, nil) != nil)
        #expect(counts(slot) == (0, 1))
        #expect(slot.load() == nil)

        let id = try slot.loadOrCreate()
        #expect(counts(slot) == (1, 1))   // the orphan was replaced, not stacked
        #expect(slot.load()?.fingerprint == id.fingerprint)
    }

    @Test func aLeftoverCertificateWithoutItsKeyIsRepaired() throws {
        let slot = Slot()
        defer { slot.reset() }
        let first = try slot.loadOrCreate()

        // Simulate the key having been deleted: the certificate alone is not an identity.
        let deleteKey: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(slot.label.utf8)]
        #expect(SecItemDelete(deleteKey as CFDictionary) == errSecSuccess)
        #expect(counts(slot) == (1, 0))
        #expect(slot.load() == nil)

        let second = try slot.loadOrCreate()
        #expect(counts(slot) == (1, 1))   // the orphan certificate was removed, not stacked
        #expect(second.fingerprint != first.fingerprint)   // a new key means a new certificate
    }

    @Test func concurrentCallsCreateExactlyOneIdentity() async throws {
        let slot = Slot()
        defer { slot.reset() }

        let fingerprints = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try? slot.loadOrCreate().fingerprint }
            }
            var all: [String?] = []
            for await fp in group { all.append(fp) }
            return all
        }
        #expect(fingerprints.count == 8)
        #expect(!fingerprints.contains(nil))
        #expect(Set(fingerprints.compactMap { $0 }).count == 1)
        #expect(counts(slot) == (1, 1))
    }
}
