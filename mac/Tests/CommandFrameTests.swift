import CryptoKit
import Foundation
import Testing

/// Mac -> phone `cmd` frames (QUIC plan stage 1.1). Until now `cmd` only travelled phone -> Mac. These tests pin the frame the Mac now
/// writes: the same `{"t":"cmd","nonce","ct"}` shape the phone writes, sealed with the v2 envelope (AAD "cmd"), and the rule that picks
/// ONE link so a command is never delivered twice.
///
/// `ClipCodec` remembers every nonce it has accepted (replay protection), so every test seals a fresh frame.
@Suite struct CommandFrameTests {
    /// 32 bytes 0x00…0x1F, base64: a fixed pairing key for the tests.
    private let key = Data((0 ..< 32).map { UInt8($0) }).base64EncodedString()
    private let otherKey = Data((0 ..< 32).map { UInt8(255 - $0) }).base64EncodedString()

    /// Builds a `cmd` envelope by hand with a chosen timestamp (what `ClipCodec.encode` does, but with the clock under test control).
    private func handSealed(_ action: String, timestampMs: UInt64, type: String = "cmd") -> (nonce: String, ct: String) {
        var plain = Data()
        withUnsafeBytes(of: timestampMs.bigEndian) { plain.append(contentsOf: $0) }
        plain.append(Data(action.utf8))
        let box = try! ChaChaPoly.seal(plain, using: SymmetricKey(data: Data(base64Encoded: key)!), authenticating: Data(type.utf8))
        return (Data(box.nonce).base64EncodedString(), (box.ciphertext + box.tag).base64EncodedString())
    }

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    // MARK: the frame

    @Test func theFrameHasTheShapeThePhoneWrites() throws {
        let frame = try #require(CommandFrame.make(action: "lock", keyBase64: key))
        #expect(Set(frame.keys) == ["t", "nonce", "ct"])
        #expect(frame["t"] as? String == "cmd")
        #expect(frame["nonce"] is String)
        #expect(frame["ct"] is String)
    }

    @Test func thePhoneSideDecodesWhatTheMacSealed() throws {
        let frame = try #require(CommandFrame.make(action: "lock", keyBase64: key))
        let action = ClipCodec.decode(nonce: frame["nonce"] as! String, ct: frame["ct"] as! String, keyBase64: key, type: "cmd")
        #expect(action == "lock")
    }

    @Test func aJSONActionSurvivesUnchangedIncludingNonASCII() throws {
        // what 1.3 will send: a JSON object inside the action string
        let action = #"{"op":"q.req","kind":"cast","sid":"a1b2c3d4","why":"Ekran yansıtma 📺 ışığı"}"#
        let sealed = try #require(CommandFrame.seal(action: action, keyBase64: key))
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: key, type: "cmd") == action)
    }

    @Test func everyFrameGetsAFreshNonce() throws {
        let a = try #require(CommandFrame.seal(action: "lock", keyBase64: key))
        let b = try #require(CommandFrame.seal(action: "lock", keyBase64: key))
        #expect(a.nonce != b.nonce)
        #expect(a.ct != b.ct)
    }

    @Test func theWrongKeyCannotOpenIt() throws {
        let sealed = try #require(CommandFrame.seal(action: "lock", keyBase64: key))
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: otherKey, type: "cmd") == nil)
    }

    @Test func theTypeIsBoundSoACmdCannotBeRelabelledAsAClip() throws {
        let sealed = try #require(CommandFrame.seal(action: "lock", keyBase64: key))
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: key, type: "clip") == nil)
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: key, type: "stat") == nil)
    }

    @Test func aReplayedFrameIsRejectedTheSecondTime() throws {
        let sealed = try #require(CommandFrame.seal(action: "lock", keyBase64: key))
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: key, type: "cmd") == "lock")
        #expect(ClipCodec.decode(nonce: sealed.nonce, ct: sealed.ct, keyBase64: key, type: "cmd") == nil)
    }

    @Test func staleAndFutureTimestampsAreRejectedButAFreshHandSealedFrameIsAccepted() {
        // positive control first: proves the hand-sealing helper builds a valid envelope
        let fresh = handSealed("lock", timestampMs: nowMs())
        #expect(ClipCodec.decode(nonce: fresh.nonce, ct: fresh.ct, keyBase64: key, type: "cmd") == "lock")

        let tenMinutes: UInt64 = 10 * 60 * 1000
        let stale = handSealed("lock", timestampMs: nowMs() - tenMinutes)
        #expect(ClipCodec.decode(nonce: stale.nonce, ct: stale.ct, keyBase64: key, type: "cmd") == nil)
        let future = handSealed("lock", timestampMs: nowMs() + tenMinutes)
        #expect(ClipCodec.decode(nonce: future.nonce, ct: future.ct, keyBase64: key, type: "cmd") == nil)
    }

    // MARK: fail closed

    @Test func aMalformedKeyProducesNoFrameAndNeverPlaintext() {
        #expect(CommandFrame.make(action: "lock", keyBase64: "not base64!!") == nil)
        #expect(CommandFrame.seal(action: "lock", keyBase64: "not base64!!") == nil)
        #expect(CommandFrame.make(action: "lock", keyBase64: Data(repeating: 1, count: 16).base64EncodedString()) == nil)   // 16 bytes, not 32
        #expect(CommandFrame.make(action: "lock", keyBase64: "") == nil)
    }

    @Test func anEmptyActionProducesNoFrame() {
        #expect(CommandFrame.make(action: "", keyBase64: key) == nil)
        #expect(CommandFrame.seal(action: "", keyBase64: key) == nil)
    }

    // MARK: the relay message

    @Test func theRelayMessageEncodesToExactlyTypeNonceAndCiphertext() throws {
        let data = try JSONEncoder().encode(ClientMessage.cmd(nonce: "AAAA", ct: "BBBB"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["t": "cmd", "nonce": "AAAA", "ct": "BBBB"])
    }

    // MARK: one link, never two

    @Test func bothLinksUpPicksTheLANOnly() {
        #expect(CommandRoute.choose(lanConnected: true, relayOnline: true) == .lan)
    }

    @Test func onlyTheRelayUpPicksTheRelay() {
        #expect(CommandRoute.choose(lanConnected: false, relayOnline: true) == .relay)
    }

    @Test func onlyTheLANUpPicksTheLAN() {
        #expect(CommandRoute.choose(lanConnected: true, relayOnline: false) == .lan)
    }

    @Test func noLinkMeansNoRouteSoNothingIsQueued() {
        #expect(CommandRoute.choose(lanConnected: false, relayOnline: false) == nil)
    }
}
