import Foundation
import Testing

@Suite struct FileFrameTests {
    @Test func singleChunkFileStillCarriesAnIdSoThePhoneAcksIt() throws {
        // The bug behind the crash: an id-less one-chunk file is never acked, so the sender
        // waited out its timeout and left its ack window short.
        let frame = FileFrame.payload(
            mime: "text/plain", bytes: Data("hi".utf8), name: "a.txt",
            disp: FileFrame.dispSave, id: "abcd1234", seq: 0, count: 1
        )
        let parsed = try #require(FileFrame.parse(frame))
        #expect(parsed.id == "abcd1234")
        #expect(parsed.count == 1)
        #expect(parsed.seq == 0)
        #expect(parsed.isSingle)
        #expect(parsed.bytes == Data("hi".utf8))
    }

    @Test func clipboardImageHasNoChunkFields() throws {
        // No id means pre-chunking bytes and no ack — an old peer still pastes the image.
        let frame = FileFrame.payload(mime: "image/png", bytes: Data([1, 2, 3]))
        let parsed = try #require(FileFrame.parse(frame))
        #expect(parsed.id == nil)
        #expect(parsed.disp == FileFrame.dispClip)
        let headerLen = Int(frame[0]) << 8 | Int(frame[1])
        let header = String(decoding: frame[2..<(2 + headerLen)], as: UTF8.self)
        #expect(header == #"{"mime":"image\/png"}"#)
    }

    @Test func dirRoundTripsAndIsOptional() throws {
        let with = FileFrame.payload(mime: "x/y", bytes: Data([9]), name: "f", dir: "Photos/2024",
                                     disp: FileFrame.dispSave, id: "i", seq: 0, count: 1)
        #expect(FileFrame.parse(with)?.dir == "Photos/2024")

        let without = FileFrame.payload(mime: "x/y", bytes: Data([9]), name: "f")
        #expect(FileFrame.parse(without)?.dir == nil)
    }

    @Test func ackAndNackRoundTrip() throws {
        let ack = try #require(FileFrame.parse(FileFrame.ack(id: "i1", seq: 3)))
        #expect(ack.op == FileFrame.opAck)
        #expect(ack.id == "i1")
        #expect(ack.seq == 3)

        let nack = try #require(FileFrame.parse(FileFrame.nack(id: "i1", seq: 3, reason: "disk full")))
        #expect(nack.op == FileFrame.opNack)
        #expect(nack.reason == "disk full")
    }

    @Test func overlongNameAndDirNeverOverflowTheHeaderLength() throws {
        let name = String(repeating: "n", count: 100_000)
        let dir = String(repeating: "d/", count: 40_000)
        let frame = FileFrame.payload(mime: "x/y", bytes: Data([7, 7]), name: name, dir: dir,
                                      disp: FileFrame.dispSave, id: "i", seq: 0, count: 1)
        let parsed = try #require(FileFrame.parse(frame))
        #expect(parsed.bytes == Data([7, 7]))
        #expect(parsed.id == "i")
        #expect(parsed.dir == nil) // shed first
        #expect((parsed.name?.count ?? 0) < name.count)
    }

    @Test func nameWithQuotesSurvives() throws {
        let frame = FileFrame.payload(mime: "x/y", bytes: Data(), name: #"we"ird\name.txt"#)
        #expect(FileFrame.parse(frame)?.name == #"we"ird\name.txt"#)
    }

    @Test func malformedPayloadIsNil() {
        #expect(FileFrame.parse(Data()) == nil)
        #expect(FileFrame.parse(Data([0x00])) == nil)
        #expect(FileFrame.parse(Data([0x00, 0x20, 0x01])) == nil) // header longer than payload
    }
}
