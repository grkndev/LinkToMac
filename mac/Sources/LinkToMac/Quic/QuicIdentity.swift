import CryptoKit
import Foundation
import Security

/// The Mac's long-lived QUIC server identity: a P-256 key in the Keychain plus a self-signed certificate over it,
/// read back as the `SecIdentity` Network.framework's QUIC listener presents.
///
/// **Why one persistent identity and not one per session:** macOS has no public API to create an X.509 certificate,
/// so we hand-write the DER (`SelfSignedCertificate`), and a `SecIdentity` needs the private key in a keychain. Doing
/// that per session would mean a Keychain write and a signature every time. The phone does not trust the certificate
/// itself; it trusts the **fingerprint**, which arrives freshly in every `q.offer` over the end-to-end encrypted
/// control channel, so a long-lived certificate costs no security.
///
/// The file-based login keychain is used (default): the app is unsandboxed, and the Data Protection keychain would
/// need a team-provisioned `keychain-access-groups` entitlement that an ad-hoc Debug build can't have.
///
/// **How the identity is found (learned the hard way, pinned by `QuicIdentityKeychainTests`):** in the file-based
/// keychain a certificate's `kSecAttrLabel` is *derived from its subject CN* (whatever label is passed to `SecItemAdd`
/// is ignored), and a `kSecClassIdentity` query ignores `kSecAttrLabel` entirely and returns the first identity in the
/// keychain (an Apple Development certificate, say), which would then be presented as the QUIC identity. So the
/// private key is found by its `kSecAttrApplicationTag`, its public-key hash (`kSecAttrApplicationLabel`) finds the
/// certificate, and `SecIdentityCreateWithCertificate` pairs the two.
///
/// Never logs: nothing here may put a fingerprint, a label or a key into a log line.
struct QuicIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateDER: Data
    /// SHA-256 of `certificateDER`, 64 lowercase hex characters: what the phone pins.
    let fingerprint: String

    /// Tag of the private key in the Keychain.
    static let defaultLabel = "dev.grkn.LinkToMac/quic-identity"
    /// Subject CN of the certificate (and therefore its Keychain label). Tests pass a unique one to stay isolated.
    static let commonName = "LinkToMac"

    enum Failure: Error, Equatable {
        case keyGeneration
        case certificate
        case keychain(OSStatus)
        case identityNotFound
    }

    /// Serialises `loadOrCreate`/`reset`: two callers racing on first launch must end up with ONE key + certificate.
    private static let lock = NSLock()

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - load / create / reset

    /// The stored identity, or nil. Never creates anything.
    static func load(label: String = defaultLabel) -> QuicIdentity? {
        guard let keyHash = privateKeyHash(label: label) else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrPublicKeyHash as String: keyHash,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let item, CFGetTypeID(item) == SecCertificateGetTypeID()
        else { return nil }
        let certificate = item as! SecCertificate   // type id checked just above

        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { return nil }

        let der = SecCertificateCopyData(certificate) as Data
        return QuicIdentity(identity: identity, certificateDER: der, fingerprint: fingerprint(of: der))
    }

    /// Loads the identity, creating it on the first call. A key without a certificate (or the reverse), left by an
    /// interrupted earlier run, is cleared and recreated rather than trusted.
    static func loadOrCreate(
        label: String = defaultLabel, commonName: String = commonName, now: Date = Date()
    ) throws -> QuicIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let existing = load(label: label) { return existing }
        deleteItems(label: label, commonName: commonName)   // orphans of a half-finished run

        let key = try makeKey(permanent: true, label: label)
        do {
            let der = try certificate(for: key, commonName: commonName, now: now)
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.certificate }
            let add: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
            ]
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }

            // Read it back as an identity: proves the certificate and the key really pair up in the keychain.
            guard let created = load(label: label), created.certificateDER == der else { throw Failure.identityNotFound }
            return created
        } catch {
            deleteItems(label: label, commonName: commonName)   // never leave a key behind that has no usable certificate
            throw error
        }
    }

    /// Removes the certificate and the key (used when the pairing is reset, so the old identity can't be reused).
    static func reset(label: String = defaultLabel, commonName: String = commonName) {
        lock.lock()
        defer { lock.unlock() }
        deleteItems(label: label, commonName: commonName)
    }

    // MARK: - certificate

    /// A self-signed certificate over `key`'s public half. Works with a non-permanent key too (tests, fixture tool).
    static func certificate(for key: SecKey, commonName: String = commonName, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw Failure.keyGeneration }

        // 16 random bytes, forced positive and non-zero: top bit clear (positive) and the next bit set, so the first
        // byte is 0x40-0x7F and the DER INTEGER is always exactly 16 bytes with no sign pad.
        var serial = Data(count: 16)
        let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.certificate }
        serial[0] = (serial[0] & 0x3F) | 0x40

        let calendar = Calendar(identifier: .gregorian)
        let notBefore = now.addingTimeInterval(-24 * 60 * 60)
        guard let notAfter = calendar.date(byAdding: .year, value: 10, to: now) else { throw Failure.certificate }

        return try SelfSignedCertificate.make(
            publicKeyX963: x963, commonName: commonName, serial: serial, notBefore: notBefore, notAfter: notAfter
        ) { tbs in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data?
            else {
                _ = error?.takeRetainedValue()
                throw Failure.certificate
            }
            return signature   // already a DER ECDSA-Sig-Value (X9.62), exactly what the certificate wants
        }
    }

    /// A P-256 key that is NOT stored anywhere: for tests and the fixture tool.
    static func makeEphemeralKey() throws -> SecKey {
        try makeKey(permanent: false, label: nil)
    }

    // MARK: - keychain plumbing

    private static func makeKey(permanent: Bool, label: String?) throws -> SecKey {
        var privateAttributes: [String: Any] = [kSecAttrIsPermanent as String: permanent]
        if let label {
            privateAttributes[kSecAttrLabel as String] = label
            privateAttributes[kSecAttrApplicationTag as String] = Data(label.utf8)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw Failure.keyGeneration
        }
        return key
    }

    /// The public-key hash of the stored private key tagged `label` (the Keychain's own link between a key and a
    /// certificate), or nil when there is no such key.
    private static func privateKeyHash(label: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(label.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any]
        else { return nil }
        return attributes[kSecAttrApplicationLabel as String] as? Data
    }

    /// Removes our private key, the certificate paired with it, and any certificate named `commonName` that no longer
    /// has a key (so a half-finished earlier run can't stack leftovers). A certificate that still pairs with some OTHER
    /// key is left alone. A single `SecItemDelete` can remove just one match in the file-based keychain, so each delete
    /// repeats until nothing matches.
    private static func deleteItems(label: String, commonName: String) {
        func deleteAll(_ query: [String: Any]) {
            var removed = 0
            while removed < 16, SecItemDelete(query as CFDictionary) == errSecSuccess { removed += 1 }
        }

        if let keyHash = privateKeyHash(label: label) {
            deleteAll([kSecClass as String: kSecClassCertificate, kSecAttrPublicKeyHash as String: keyHash])
        }
        deleteAll([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(label.utf8)])

        let named: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: commonName,   // a certificate's label is its subject CN
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(named as CFDictionary, &items) == errSecSuccess,
              let certificates = items as? [SecCertificate]
        else { return }
        for certificate in certificates {
            var identity: SecIdentity?
            if SecIdentityCreateWithCertificate(nil, certificate, &identity) != errSecSuccess {
                SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
            }
        }
    }
}
