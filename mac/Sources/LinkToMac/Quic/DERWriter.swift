import Foundation

// A minimal DER (ITU-T X.690) encoder, and on top of it the one X.509 structure the QUIC server needs: a
// self-signed P-256 certificate.
//
// WHY THIS EXISTS: macOS can *parse* certificates (`SecCertificateCreateWithData`) but has no public API to
// *create* one, and Network.framework's QUIC listener needs a `SecIdentity` (certificate + private key). The
// usual answers are a third-party package (swift-certificates) or shelling out to openssl; the project rule is
// "system frameworks + Sparkle only", so we write the ~100 bytes of structure by hand.
//
// Foundation only on purpose (no Security): the signature is supplied by the caller as a closure, so this file
// compiles into the test target, and the certificate can be built and verified without touching the Keychain.

enum DERError: Error, Equatable {
    /// UTCTime only covers 1950-2049 (RFC 5280 §4.1.2.5); later dates need GeneralizedTime, which isn't written here.
    case timeOutOfRange
    /// Not a 65-byte uncompressed P-256 point (`04 ‖ X ‖ Y`).
    case invalidPublicKey
    /// RFC 5280 §4.1.2.2: a serial is a positive integer of at most 20 octets.
    case invalidSerial
    case invalidValidity
}

enum DER {
    /// Definite length: short form below 128, otherwise `0x80 | byteCount` followed by the big-endian length.
    static func length(_ n: Int) -> Data {
        precondition(n >= 0, "DER length can't be negative")
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var rest = n
        while rest > 0 {
            bytes.append(UInt8(rest & 0xFF))
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes.reversed())
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func sequence(_ parts: [Data]) -> Data { tlv(0x30, concat(parts)) }

    static func set(_ parts: [Data]) -> Data { tlv(0x31, concat(parts)) }

    /// A non-negative INTEGER from big-endian magnitude bytes: redundant leading zeros are dropped, and a `00` pad
    /// is added when the top bit is set (otherwise the value would read as negative).
    static func integer(unsignedBigEndian bytes: Data) -> Data {
        var magnitude = Array(bytes.drop { $0 == 0 })
        if magnitude.isEmpty { magnitude = [0] }
        if magnitude[0] & 0x80 != 0 { magnitude.insert(0, at: 0) }
        return tlv(0x02, Data(magnitude))
    }

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0, "only non-negative integers are needed")
        var bytes: [UInt8] = []
        var rest = value
        repeat {
            bytes.append(UInt8(rest & 0xFF))
            rest >>= 8
        } while rest > 0
        return integer(unsignedBigEndian: Data(bytes.reversed()))
    }

    /// OBJECT IDENTIFIER: the first two arcs share one byte (`40·a + b`), every arc is base-128 with the
    /// continuation bit set on all but its last group.
    static func oid(_ arcs: [UInt]) -> Data {
        precondition(arcs.count >= 2 && arcs[0] <= 2, "an OID needs at least two arcs, the first 0-2")
        var body = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { body += base128(arc) }
        return tlv(0x06, Data(body))
    }

    static func utf8String(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }

    /// UTCTime `YYMMDDHHMMSSZ` in UTC. Throws outside 1950-2049, where two-digit years stop being unambiguous.
    static func utcTime(_ date: Date) throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, (1950 ... 2049).contains(year),
              let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let second = c.second
        else { throw DERError.timeOutOfRange }
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ", year % 100, month, day, hour, minute, second)
        return tlv(0x17, Data(text.utf8))
    }

    /// BIT STRING: one leading byte counts the unused bits of the last octet, then the bits.
    static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
        precondition(unusedBits < 8, "at most 7 unused bits")
        var content = Data([unusedBits])
        content.append(bytes)
        return tlv(0x03, content)
    }

    /// `[n] EXPLICIT`: a constructed, context-specific wrapper (`0xA0 | n`) around a complete inner TLV.
    static func contextExplicit(_ n: UInt8, _ inner: Data) -> Data {
        precondition(n < 31, "high tag numbers aren't needed")
        return tlv(0xA0 | n, inner)
    }

    private static func concat(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    private static func base128(_ value: UInt) -> [UInt8] {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        return groups.reversed()
    }
}

/// A self-signed X.509 v3 certificate over a P-256 key, signed with ecdsa-with-SHA256, with no extensions.
///
/// Only the peer that pinned its fingerprint ever looks at it (the phone compares SHA-256 of the DER and ignores
/// everything else), so a minimal certificate is enough; it just has to be well-formed for Network.framework to
/// present it and for rustls/webpki-style parsers to read it.
enum SelfSignedCertificate {
    enum OID {
        static let ecdsaWithSHA256: [UInt] = [1, 2, 840, 10045, 4, 3, 2]
        static let idEcPublicKey: [UInt] = [1, 2, 840, 10045, 2, 1]
        static let prime256v1: [UInt] = [1, 2, 840, 10045, 3, 1, 7]
        static let commonName: [UInt] = [2, 5, 4, 3]
    }

    /// `ecdsa-with-SHA256`. RFC 5758 §3.2: the parameters field MUST be absent (not NULL).
    private static var signatureAlgorithm: Data { DER.sequence([DER.oid(OID.ecdsaWithSHA256)]) }

    /// The to-be-signed part. `publicKeyX963` is `SecKeyCopyExternalRepresentation` output for a P-256 key.
    static func tbs(publicKeyX963: Data, commonName: String, serial: Data, notBefore: Date, notAfter: Date) throws -> Data {
        guard publicKeyX963.count == 65, publicKeyX963.first == 0x04 else { throw DERError.invalidPublicKey }

        let magnitude = serial.drop { $0 == 0 }
        guard let top = magnitude.first else { throw DERError.invalidSerial }   // empty, or all zero
        let encodedLength = magnitude.count + (top & 0x80 != 0 ? 1 : 0)         // the 00 pad counts
        guard encodedLength <= 20 else { throw DERError.invalidSerial }

        guard notBefore < notAfter else { throw DERError.invalidValidity }

        let name = DER.sequence([DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])])])
        let validity = DER.sequence([try DER.utcTime(notBefore), try DER.utcTime(notAfter)])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([DER.oid(OID.idEcPublicKey), DER.oid(OID.prime256v1)]),
            DER.bitString(publicKeyX963),
        ])

        return DER.sequence([
            DER.contextExplicit(0, DER.integer(2)),     // version: v3
            DER.integer(unsignedBigEndian: serial),
            signatureAlgorithm,
            name,                                       // issuer
            validity,
            name,                                       // subject = issuer (self-signed)
            subjectPublicKeyInfo,
        ])
    }

    /// The complete certificate: `SEQUENCE { tbs, signatureAlgorithm, BIT STRING(signature) }`.
    /// `sign` receives exactly the TBS bytes and returns a DER ECDSA-Sig-Value (what
    /// `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` and CryptoKit's `derRepresentation` produce).
    static func make(
        publicKeyX963: Data, commonName: String, serial: Data, notBefore: Date, notAfter: Date,
        sign: (Data) throws -> Data
    ) throws -> Data {
        let tbs = try tbs(
            publicKeyX963: publicKeyX963, commonName: commonName, serial: serial,
            notBefore: notBefore, notAfter: notAfter)
        let signature = try sign(tbs)
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString(signature)])
    }
}
