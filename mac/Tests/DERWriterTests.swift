import Foundation
import Testing

/// The DER encoder behind the QUIC server certificate (stage 0.2). macOS has no public API to *create* an X.509
/// certificate, so `DERWriter.swift` writes the few structures a self-signed P-256 certificate needs by hand. These
/// tests pin every primitive against the X.690 rules, and pin the whole TBSCertificate against bytes produced by an
/// **independent** encoder (`openssl asn1parse -genconf`), so a mistake in both the writer and its test can't agree.
@Suite struct DERWriterTests {
    // MARK: - helpers

    private func hex(_ s: String) -> Data {
        let chars = Array(s.filter { !$0.isWhitespace })
        precondition(chars.count % 2 == 0, "odd hex length")
        var out = Data()
        var i = 0
        while i < chars.count {
            out.append(UInt8(String(chars[i ... i + 1]), radix: 16)!)
            i += 2
        }
        return out
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    /// Splits one TLV off the front: (tag, content, remainder). Reads both length forms.
    private func readTLV(_ data: Data) -> (tag: UInt8, content: Data, rest: Data) {
        let bytes = [UInt8](data)
        let tag = bytes[0]
        var length = Int(bytes[1])
        var header = 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            for i in 0 ..< count { length = (length << 8) | Int(bytes[2 + i]) }
            header = 2 + count
        }
        return (tag, Data(bytes[header ..< header + length]), Data(bytes[(header + length)...]))
    }

    // MARK: - primitives

    @Test func lengthShortAndLongForms() {
        #expect(DER.length(0) == hex("00"))
        #expect(DER.length(127) == hex("7f"))
        #expect(DER.length(128) == hex("81 80"))
        #expect(DER.length(255) == hex("81 ff"))
        #expect(DER.length(256) == hex("82 01 00"))
        #expect(DER.length(65535) == hex("82 ff ff"))
        #expect(DER.length(65536) == hex("83 01 00 00"))
    }

    @Test func tlvPrependsTagAndLength() {
        #expect(DER.tlv(0x04, Data([1, 2, 3])) == hex("04 03 01 02 03"))
        #expect(DER.tlv(0x04, Data(repeating: 0xAA, count: 200)).prefix(3) == hex("04 81 c8"))
    }

    @Test func integerIsMinimalAndPositive() {
        #expect(DER.integer(unsignedBigEndian: Data()) == hex("02 01 00"))
        #expect(DER.integer(unsignedBigEndian: hex("00")) == hex("02 01 00"))
        #expect(DER.integer(unsignedBigEndian: hex("01")) == hex("02 01 01"))
        #expect(DER.integer(unsignedBigEndian: hex("7f")) == hex("02 01 7f"))
        // A set top bit would read as negative, so a 00 pad is mandatory.
        #expect(DER.integer(unsignedBigEndian: hex("80")) == hex("02 02 00 80"))
        #expect(DER.integer(unsignedBigEndian: hex("ff")) == hex("02 02 00 ff"))
        #expect(DER.integer(unsignedBigEndian: hex("01 00")) == hex("02 02 01 00"))
        // Redundant leading zeros are stripped; a pad is re-added only when the next byte needs one.
        #expect(DER.integer(unsignedBigEndian: hex("00 00 05")) == hex("02 01 05"))
        #expect(DER.integer(unsignedBigEndian: hex("00 80")) == hex("02 02 00 80"))
        #expect(DER.integer(2) == hex("02 01 02"))
    }

    @Test func objectIdentifiers() {
        #expect(DER.oid(SelfSignedCertificate.OID.ecdsaWithSHA256) == hex("06 08 2a 86 48 ce 3d 04 03 02"))
        #expect(DER.oid(SelfSignedCertificate.OID.idEcPublicKey) == hex("06 07 2a 86 48 ce 3d 02 01"))
        #expect(DER.oid(SelfSignedCertificate.OID.prime256v1) == hex("06 08 2a 86 48 ce 3d 03 01 07"))
        #expect(DER.oid(SelfSignedCertificate.OID.commonName) == hex("06 03 55 04 03"))
        // A multi-byte arc: 840 = 0x348 -> 86 48 (base 128, high groups carry the continuation bit).
        #expect(DER.oid([1, 2, 840]) == hex("06 03 2a 86 48"))
    }

    @Test func utf8String() {
        #expect(DER.utf8String("LinkToMac") == hex("0c 09 4c 69 6e 6b 54 6f 4d 61 63"))
        #expect(DER.utf8String("") == hex("0c 00"))
    }

    @Test func utcTimeFormatAndRange() throws {
        #expect(try DER.utcTime(utc(2026, 11, 13, 12, 0, 0)) == hex("17 0d") + Data("261113120000Z".utf8))
        #expect(try DER.utcTime(utc(1950, 1, 1)) == hex("17 0d") + Data("500101000000Z".utf8))
        #expect(try DER.utcTime(utc(2049, 12, 31, 23, 59, 59)) == hex("17 0d") + Data("491231235959Z".utf8))
        // RFC 5280: UTCTime only covers 1950-2049; later dates must be GeneralizedTime, which we don't write.
        #expect(throws: DERError.timeOutOfRange) { try DER.utcTime(utc(2050, 1, 1)) }
        #expect(throws: DERError.timeOutOfRange) { try DER.utcTime(utc(1949, 12, 31, 23, 59, 59)) }
    }

    @Test func bitString() {
        #expect(DER.bitString(hex("ab")) == hex("03 02 00 ab"))
        #expect(DER.bitString(Data()) == hex("03 01 00"))
        #expect(DER.bitString(hex("f0"), unusedBits: 4) == hex("03 02 04 f0"))
    }

    @Test func constructedTypes() {
        #expect(DER.sequence([]) == hex("30 00"))
        #expect(DER.sequence([DER.integer(1), DER.integer(2)]) == hex("30 06 02 01 01 02 01 02"))
        #expect(DER.set([DER.integer(1)]) == hex("31 03 02 01 01"))
        #expect(DER.contextExplicit(0, DER.integer(2)) == hex("a0 03 02 01 02"))
        #expect(DER.contextExplicit(3, hex("05 00")) == hex("a3 02 05 00"))
        // Content over 127 bytes switches the header to the long length form.
        let big = DER.sequence([DER.tlv(0x04, Data(repeating: 0, count: 200))])
        #expect(big.prefix(4) == hex("30 81 cb 04"))
    }

    // MARK: - TBSCertificate

    /// RFC 6979 A.2.5 public point for NIST P-256, a published test key: 04 || Ux || Uy.
    private let fixedPublicKey = Data(hex: "04"
        + "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6"
        + "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
    private let fixedSerial = Data(hex: "0102030405060708090a0b0c0d0e0f10")

    /// Produced by `openssl asn1parse -genconf` from the same inputs (see docs/plans/2026-11-14-quic-faz0-sonuclar.md):
    /// v3, serial 0102..0f10, ecdsa-with-SHA256, issuer = subject = CN=LinkToMac, 2026-11-13 12:00:00Z .. 2036-11-14 12:00:00Z,
    /// SPKI id-ecPublicKey + prime256v1 over the fixed point, no extensions.
    private let goldenTBS = Data(hex: "3081caa00302010202100102030405060708090a0b0c0d0e0f10300a06082a8648ce3d04030230143112301006035504030c094c696e6b546f4d6163301e170d3236313131333132303030305a170d3336313131343132303030305a30143112301006035504030c094c696e6b546f4d61633059301306072a8648ce3d020106082a8648ce3d0301070342000460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299")

    @Test func tbsMatchesTheIndependentlyEncodedVector() throws {
        let tbs = try SelfSignedCertificate.tbs(
            publicKeyX963: fixedPublicKey, commonName: "LinkToMac", serial: fixedSerial,
            notBefore: utc(2026, 11, 13, 12), notAfter: utc(2036, 11, 14, 12))
        #expect(tbs == goldenTBS)
    }

    @Test func tbsRejectsAMalformedPublicKey() {
        func tbs(_ key: Data) throws -> Data {
            try SelfSignedCertificate.tbs(
                publicKeyX963: key, commonName: "LinkToMac", serial: fixedSerial,
                notBefore: utc(2026, 11, 13), notAfter: utc(2036, 11, 14))
        }
        #expect(throws: DERError.invalidPublicKey) { try tbs(Data()) }
        #expect(throws: DERError.invalidPublicKey) { try tbs(fixedPublicKey.dropLast()) }          // 64 bytes
        #expect(throws: DERError.invalidPublicKey) { try tbs(fixedPublicKey + Data([0])) }         // 66 bytes
        var compressed = fixedPublicKey
        compressed[0] = 0x02                                                                        // not an uncompressed point
        #expect(throws: DERError.invalidPublicKey) { try tbs(compressed) }
    }

    @Test func tbsRejectsAnInvalidSerial() {
        func tbs(_ serial: Data) throws -> Data {
            try SelfSignedCertificate.tbs(
                publicKeyX963: fixedPublicKey, commonName: "LinkToMac", serial: serial,
                notBefore: utc(2026, 11, 13), notAfter: utc(2036, 11, 14))
        }
        #expect(throws: DERError.invalidSerial) { try tbs(Data()) }
        #expect(throws: DERError.invalidSerial) { try tbs(Data(repeating: 0, count: 16)) }         // RFC 5280: non-zero
        #expect(throws: DERError.invalidSerial) { try tbs(Data(repeating: 1, count: 21)) }         // RFC 5280: <= 20 octets
    }

    @Test func tbsRejectsAnInvertedValidityWindow() {
        #expect(throws: DERError.invalidValidity) {
            try SelfSignedCertificate.tbs(
                publicKeyX963: fixedPublicKey, commonName: "LinkToMac", serial: fixedSerial,
                notBefore: utc(2036, 11, 14), notAfter: utc(2026, 11, 13))
        }
    }

    // MARK: - the signed certificate

    @Test func makeWrapsTbsAlgorithmAndSignature() throws {
        let fakeSignature = hex("30 06 02 01 01 02 01 01")      // shaped like an ECDSA-Sig-Value; the writer never inspects it
        var signedOver: Data?
        let cert = try SelfSignedCertificate.make(
            publicKeyX963: fixedPublicKey, commonName: "LinkToMac", serial: fixedSerial,
            notBefore: utc(2026, 11, 13, 12), notAfter: utc(2036, 11, 14, 12)
        ) { tbs in
            signedOver = tbs
            return fakeSignature
        }

        // The signer is handed exactly the TBS bytes that end up in the certificate.
        #expect(signedOver == goldenTBS)

        let outer = readTLV(cert)
        #expect(outer.tag == 0x30)
        #expect(outer.rest.isEmpty)
        let tbsPart = readTLV(outer.content)
        #expect(tbsPart.tag == 0x30)
        #expect(outer.content.prefix(goldenTBS.count) == goldenTBS)
        let algPart = readTLV(tbsPart.rest)
        #expect(algPart.tag == 0x30)
        #expect(algPart.content == hex("06 08 2a 86 48 ce 3d 04 03 02"))      // ecdsa-with-SHA256, parameters absent
        let sigPart = readTLV(algPart.rest)
        #expect(sigPart.tag == 0x03)
        #expect(sigPart.content == Data([0x00]) + fakeSignature)              // BIT STRING, 0 unused bits
        #expect(sigPart.rest.isEmpty)
    }

    @Test func makePropagatesASigningFailure() {
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try SelfSignedCertificate.make(
                publicKeyX963: fixedPublicKey, commonName: "LinkToMac", serial: fixedSerial,
                notBefore: utc(2026, 11, 13), notAfter: utc(2036, 11, 14)
            ) { _ in throw Boom() }
        }
    }
}

private extension Data {
    /// Test-only: hex literal to bytes (no whitespace).
    init(hex: String) {
        let chars = Array(hex)
        precondition(chars.count % 2 == 0, "odd hex length")
        var out = Data()
        var i = 0
        while i < chars.count {
            out.append(UInt8(String(chars[i ... i + 1]), radix: 16)!)
            i += 2
        }
        self = out
    }
}
