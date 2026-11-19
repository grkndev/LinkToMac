import Foundation
import Testing

/// The `q.*` actions that open and close a QUIC session (plan stage 1.3). They ride inside the E2E `cmd` envelope as a JSON string.
/// The Kotlin mirror (`QuicControlTest`) runs the SAME cases; the golden strings below must stay byte-identical in both files.
@Suite struct QuicControlTests {
    private let sid = "123e4567-e89b-12d3-a456-426614174000"
    private let fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"          // bytes 0x00...0x1F, base64url, no padding
    private let tokUrlChars = "----------------------------------------__8"   // exercises '-' and '_'

    private func parse(_ s: String, echo: Bool = false) -> QuicParse { QuicControl.parse(s, allowEcho: echo) }
    private func offerJSON(sid: String? = nil, port: String = "53125", fp: String? = nil, tok: String? = nil, extra: String = "") -> String {
        #"{"a":"q.offer","sid":"\#(sid ?? self.sid)","port":\#(port),"fp":"\#(fp ?? self.fp)","tok":"\#(tok ?? self.tok)"\#(extra)}"#
    }

    // MARK: each action parses

    @Test func aRequestParses() {
        #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":"cast"}"#) == .action(.request(sid: sid, kind: .cast)))
        for kind in ["cast", "file", "audio", "cam"] {
            #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":"\#(kind)"}"#) == .action(.request(sid: sid, kind: QuicKind(rawValue: kind)!)))
        }
    }

    @Test func anAcceptParses() { #expect(parse(#"{"a":"q.accept","sid":"\#(sid)"}"#) == .action(.accept(sid: sid))) }
    @Test func anEndParses() { #expect(parse(#"{"a":"q.end","sid":"\#(sid)"}"#) == .action(.end(sid: sid))) }

    @Test func aRejectParsesWithEveryReason() {
        for reason in ["relay", "busy", "denied", "unsupported", "timeout"] {
            #expect(parse(#"{"a":"q.reject","sid":"\#(sid)","reason":"\#(reason)"}"#) == .action(.reject(sid: sid, reason: QuicRejectReason(rawValue: reason)!)))
        }
    }

    @Test func anOfferParsesWithAllItsFields() {
        #expect(parse(offerJSON()) == .action(.offer(QuicOffer(sid: sid, port: 53125, fp: fp, tok: tok))))
        #expect(parse(offerJSON(tok: tokUrlChars)) == .action(.offer(QuicOffer(sid: sid, port: 53125, fp: fp, tok: tokUrlChars))))
    }

    @Test func theSessionIdIsNormalisedToLowerCase() {
        // the Mac writes UUID.uuidString (upper case), the phone UUID.toString() (lower case)
        let upper = sid.uppercased()
        #expect(parse(#"{"a":"q.accept","sid":"\#(upper)"}"#) == .action(.accept(sid: sid)))
    }

    @Test func unknownExtraFieldsAreIgnoredSoNewerPeersStillWork() {
        let withExtras = offerJSON(extra: #","audio":{"t":"dgram"},"future":[1,2,3],"x":null"#)
        #expect(parse(withExtras) == .action(.offer(QuicOffer(sid: sid, port: 53125, fp: fp, tok: tok))))
        #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":"file","name":"a.bin","size":123}"#) == .action(.request(sid: sid, kind: .file)))
    }

    // MARK: encode (canonical, byte-identical with the Kotlin side)

    // GOLDEN-BEGIN
    // req     {"a":"q.req","kind":"cast","sid":"123e4567-e89b-12d3-a456-426614174000"}
    // accept  {"a":"q.accept","sid":"123e4567-e89b-12d3-a456-426614174000"}
    // offer   {"a":"q.offer","fp":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","port":53125,"sid":"123e4567-e89b-12d3-a456-426614174000","tok":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}
    // reject  {"a":"q.reject","reason":"busy","sid":"123e4567-e89b-12d3-a456-426614174000"}
    // end     {"a":"q.end","sid":"123e4567-e89b-12d3-a456-426614174000"}
    // GOLDEN-END
    @Test func encodingMatchesTheGoldenStrings() {
        #expect(QuicControl.encode(.request(sid: sid, kind: .cast)) == #"{"a":"q.req","kind":"cast","sid":"123e4567-e89b-12d3-a456-426614174000"}"#)
        #expect(QuicControl.encode(.accept(sid: sid)) == #"{"a":"q.accept","sid":"123e4567-e89b-12d3-a456-426614174000"}"#)
        #expect(QuicControl.encode(.offer(QuicOffer(sid: sid, port: 53125, fp: fp, tok: tok)))
            == #"{"a":"q.offer","fp":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","port":53125,"sid":"123e4567-e89b-12d3-a456-426614174000","tok":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#)
        #expect(QuicControl.encode(.reject(sid: sid, reason: .busy)) == #"{"a":"q.reject","reason":"busy","sid":"123e4567-e89b-12d3-a456-426614174000"}"#)
        #expect(QuicControl.encode(.end(sid: sid)) == #"{"a":"q.end","sid":"123e4567-e89b-12d3-a456-426614174000"}"#)
    }

    @Test func everyEncodedActionParsesBackToItself() {
        let actions: [QuicAction] = [
            .request(sid: sid, kind: .cast), .request(sid: sid, kind: .file), .request(sid: sid, kind: .audio), .request(sid: sid, kind: .cam),
            .accept(sid: sid), .end(sid: sid),
            .reject(sid: sid, reason: .relay), .reject(sid: sid, reason: .timeout),
            .offer(QuicOffer(sid: sid, port: 1024, fp: fp, tok: tok)), .offer(QuicOffer(sid: sid, port: 65535, fp: fp, tok: tokUrlChars)),
        ]
        for a in actions { #expect(parse(QuicControl.encode(a)) == .action(a), "\(a)") }
    }

    @Test func encodingLowerCasesASessionIdSoBothSidesWriteTheSameBytes() {
        #expect(QuicControl.encode(.end(sid: sid.uppercased())) == QuicControl.encode(.end(sid: sid)))
    }

    @Test func theEchoKindEncodesAndParsesWhenAllowed() {
        let text = QuicControl.encode(.request(sid: sid, kind: .echo))
        #expect(parse(text, echo: true) == .action(.request(sid: sid, kind: .echo)))
    }

    // MARK: validation: session id

    @Test func aBadSessionIdIsInvalid() {
        let bad = ["", "123", "123e4567e89b12d3a456426614174000", "{123e4567-e89b-12d3-a456-426614174000}",
                   "123e4567-e89b-12d3-a456-42661417400g", "123e4567-e89b-12d3-a456-4266141740000", "123e4567-e89b-12d3-a456-42661417400"]
        for s in bad { #expect(parse(#"{"a":"q.accept","sid":"\#(s)"}"#) == .invalid("sid"), "\(s)") }
        #expect(parse(#"{"a":"q.accept"}"#) == .invalid("sid"))
        #expect(parse(#"{"a":"q.accept","sid":123}"#) == .invalid("sid"))
        #expect(parse(#"{"a":"q.end","sid":null}"#) == .invalid("sid"))
    }

    // MARK: validation: kind

    @Test func aBadKindIsInvalid() {
        for k in ["video", "CAST", "Cast", "", "cast ", "echo"] { #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":"\#(k)"}"#) == .invalid("kind"), "\(k)") }
        #expect(parse(#"{"a":"q.req","sid":"\#(sid)"}"#) == .invalid("kind"))
        #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":1}"#) == .invalid("kind"))
    }

    @Test func theEchoKindOnlyExistsInADebugBuild() {
        let text = #"{"a":"q.req","sid":"\#(sid)","kind":"echo"}"#
        #expect(parse(text, echo: false) == .invalid("kind"))
        #expect(parse(text, echo: true) == .action(.request(sid: sid, kind: .echo)))
    }

    // MARK: validation: port

    @Test func thePortMustBeAnIntegerInTheUnprivilegedRange() {
        for good in ["1024", "53125", "65535"] { #expect(parse(offerJSON(port: good)).isAction, "\(good)") }
        for bad in ["1023", "65536", "0", "-1", "99999999999999999999", "53125.5", "53125.0", "5.3125e4", "true", "null", #""53125""#, "[]"] {
            #expect(parse(offerJSON(port: bad)) == .invalid("port"), "\(bad)")
        }
        #expect(parse(#"{"a":"q.offer","sid":"\#(sid)","fp":"\#(fp)","tok":"\#(tok)"}"#) == .invalid("port"))
    }

    // MARK: validation: fp

    @Test func theFingerprintIsExactly64LowerCaseHexCharacters() {
        for bad in [String(fp.dropLast()), fp + "a", fp.uppercased(), String(repeating: "g", count: 64), ""] {
            #expect(parse(offerJSON(fp: bad)) == .invalid("fp"), "\(bad)")
        }
        #expect(parse(#"{"a":"q.offer","sid":"\#(sid)","port":53125,"tok":"\#(tok)"}"#) == .invalid("fp"))
        #expect(parse(#"{"a":"q.offer","sid":"\#(sid)","port":53125,"fp":7,"tok":"\#(tok)"}"#) == .invalid("fp"))
    }

    // MARK: validation: tok

    @Test func theTokenIsCanonicalUnpaddedBase64urlOf32Bytes() {
        let bad = [
            String(tok.dropLast()),                 // 42 characters
            tok + "A",                              // 44 characters
            tok + "=",                              // padded
            String(tok.dropLast()) + "+",           // '+' is standard base64, not url-safe
            String(tok.dropLast()) + "/",
            String(tok.dropLast()) + "9",           // right length and alphabet, but not the canonical encoding of any 32 bytes
            String(repeating: "A", count: 42) + " ",
            "",
        ]
        for t in bad { #expect(parse(offerJSON(tok: t)) == .invalid("tok"), "\(t)") }
        #expect(parse(#"{"a":"q.offer","sid":"\#(sid)","port":53125,"fp":"\#(fp)"}"#) == .invalid("tok"))
    }

    // MARK: validation: reason

    @Test func aBadRejectReasonIsInvalid() {
        for r in ["nope", "BUSY", "", "busy "] { #expect(parse(#"{"a":"q.reject","sid":"\#(sid)","reason":"\#(r)"}"#) == .invalid("reason"), "\(r)") }
        #expect(parse(#"{"a":"q.reject","sid":"\#(sid)"}"#) == .invalid("reason"))
        #expect(parse(#"{"a":"q.reject","sid":"\#(sid)","reason":3}"#) == .invalid("reason"))
    }

    // MARK: size limit

    @Test func theActionLimitIs4096BytesNotCharacters() {
        func padded(toBytes target: Int) -> String {
            let head = #"{"a":"q.end","sid":"\#(sid)","x":""#, tail = #""}"#
            let pad = target - head.utf8.count - tail.utf8.count
            return head + String(repeating: "a", count: pad) + tail
        }
        let exact = padded(toBytes: 4096)
        #expect(exact.utf8.count == 4096)
        #expect(parse(exact) == .action(.end(sid: sid)))
        #expect(parse(padded(toBytes: 4097)) == .invalid("too-large"))
        // 2049 two-byte characters are fewer than 4096 characters but more than 4096 bytes
        let twoByte = #"{"a":"q.end","sid":"\#(sid)","x":"\#(String(repeating: "é", count: 2049))"}"#
        #expect(twoByte.count < 4096 && twoByte.utf8.count > 4096)
        #expect(parse(twoByte) == .invalid("too-large"))
    }

    // MARK: unknown vs invalid vs not JSON

    @Test func anObjectWithAnUnknownOrMissingActionIsUnknownNotAnError() {
        for text in [#"{"a":"q.future","sid":"\#(sid)"}"#, "{}", #"{"a":5}"#, #"{"a":null}"#, #"{"sid":"\#(sid)"}"#, #"{"a":""}"#, #"{"a":"Q.REQ","sid":"\#(sid)","kind":"cast"}"#] {
            #expect(parse(text) == .unknown, "\(text)")
        }
    }

    @Test func textThatIsNotAJSONObjectIsInvalidAndNeverThrows() {
        // a trailing comma is deliberately not in this list: both JSON parsers (Foundation, org.json) tolerate it, so it is undefined, not invalid
        for text in ["", "{", #"{"a":"q.end""#, "[1,2]", "5", "null", "lock", "not json at all", "\u{0}", "{{}}"] {
            #expect(parse(text) == .invalid("bad-json"), "\(text)")
        }
    }

    @Test func theDebugEchoGateDoesNotAffectOtherKinds() {
        #expect(parse(#"{"a":"q.req","sid":"\#(sid)","kind":"cam"}"#, echo: true) == .action(.request(sid: sid, kind: .cam)))
    }
}

private extension QuicParse {
    var isAction: Bool { if case .action = self { return true } else { return false } }
}
