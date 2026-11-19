# Protocol vectors

Shared test vectors for the wire formats that are **mirrored by hand** in two languages. Both codecs must
pass every case, so a change on one side that the other doesn't follow turns a test red instead of
silently breaking sync (the Mac once omitted `id` on one-chunk files while the phone wrote it — every file
under 640 KiB then waited out a 30 s timeout).

| File | Format | Swift | Kotlin |
|---|---|---|---|
| `file-frame.json` | the `file` frame plaintext: `u16 BE header-len ‖ header JSON ‖ raw bytes` | `mac/Tests/FileFrameVectorTests.swift` | `mobile/modules/selfadb/android/src/test/…/FileFrameVectorTest.kt` |
| `dir-sanitize.json` | how a peer-supplied `dir` (folder path) is made safe to write under the download folder | `FileFrameVectorTests.dirSanitizeVectors` (→ `FileDropStore.sanitizeDir`) | `FileFrameVectorTest.dirSanitizeVectors` (→ `FileSink.sanitizeDir`) |
| `quic-control.json` | the QUIC control plane; so far only `stat.caps` (which side speaks `q1`) | `mac/Tests/QuicCapsVectorTests.swift` | `mobile/modules/selfadb/android/src/test/java/expo/modules/selfadb/QuicCapsVectorTest.kt` |
| `stat-media.json` | the media fields inside the `stat` plaintext: `media` / `mediaArt` (phone → Mac) and `mediaCmd` (Mac → phone) | `mac/Tests/NowPlayingTests.swift` (→ `NowPlaying.parse`, `MediaCommand`) | `…/MediaStateTest.kt` (→ `MediaState.toJson`, `parseCommand`) |

Not a vector but a contract in the same spirit: **`FileFrame.maxTransferBytes` (Swift) and
`FileFrame.MAX_TRANSFER_BYTES` (Kotlin) must be equal** (1 GiB) — otherwise one side accepts a file the
other then drops. Both receivers stream chunks to disk, so it is a time/space limit, not a memory one.

## `file-frame.json`

Each case has a `kind`:

- **`roundtrip`** — `params` is what a sender is asked to build, `header` the header JSON it must produce,
  `frame_hex` a canonical encoding, and `parsed` what a receiver must read back out of it. Each side checks
  *both* directions: `parse(frame_hex) == parsed`, and `encode(params)` yields a frame whose header equals
  `header` and whose body equals `bytes_hex`.
- **`fits`** — an over-long name/directory (`*_repeat` expands to the string). The header must stay inside
  the u16 length prefix, with `dir` shed first and `name` shortened, and the chunk fields and bytes intact.
- **`malformed`** — `frame_hex` must parse to nothing.

`ack` frames may carry `have` (leading chunks already stored, for resume); it is `null` in `parsed` when absent.

Headers are compared as **objects**, not bytes: `JSONSerialization` (Swift) and `org.json` (Kotlin) don't
agree on key order, so byte-equal headers would be impossible and add nothing.

Run them:

```sh
cd mac && xcodegen generate && xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' test
cd mobile/android && ./gradlew :selfadb:testDebugUnitTest
```

When you change the frame format, change the vectors **and both codecs** in the same commit.

### `dir-sanitize.json`

`{name, input, expected}` — `input` may be `null`. ASCII only: Kotlin caps a part at 100 UTF-16 units and Swift at 100
Characters, so the cap isn't pinned for surrogate pairs.

## `stat-media.json`

Media rides inside the existing `stat` frame (every `stat` field is optional and a receiver updates only what is present, so no new frame type and no relay change). Each case has a `kind`:

- **`state`** — `wire` is the `media` object the phone must produce for that track, byte-for-byte in keys (blank `artist`/`album` and an unknown `dur` are *omitted*, not sent empty), and `expect` is what the Mac must read back out of it.
- **`special`** — a non-track state: `{"media": null}` (nothing playing, clear the card) and `{"media": {"on": false, "reason": "no-access"}}` (the phone can't see sessions: no notification access).
- **`absent`** — a stat with no `media` field (battery, proximity): the Mac must leave the card alone.
- **`parse_only`** — Mac-side leniency (an unknown `state` reads as `stopped`, a garbage `media` is ignored).
- **`command`** — a `mediaCmd` the Mac builds and the phone reads (`toggle`/`play`/`pause`/`next`/`prev`, `seek` with ms, `vol` with a level); **`phone_only`** — what the phone must refuse (an unknown action, a seek with no value or a negative one, a stat with no command).
- **`position`** — the progress arithmetic both sides share: `pos + dt × speed` while playing, frozen while paused/buffering, clamped to `[0, dur]` (no upper bound when `dur` is unknown).

The `title`/`artist` in these vectors are made up; the log-privacy rule applies to real ones (never logged).

## `quic-control.json`

The QUIC control plane (plan `docs/plans/2026-11-14-quic-data-plane.md`). Only the **`stat`** section exists so far (stage 1.4): the optional
`caps` array of the `stat` plaintext, by which each side learns whether the other speaks the QUIC session protocol (`q1`). Each section is
`{ description, cases }`, like the other files.

- **`parse`** — a decoded stat object and the update it must give: `absent` (no usable `caps`: the receiver keeps what it has, so a battery or
  proximity stat never clobbers it; also a `caps` that is not an array) or `set` with the known names (unknown names and non-string items are
  ignored; `[]` means "supports none"; names are case-sensitive).
- **`sequence`** — steps (`stat` with an object, `offline`) applied in order to a fresh `PeerCaps`, and the set expected after each step. The
  peer going offline clears it; until a stat with `caps` arrives the peer counts as not supporting QUIC.
- **`available`** — `quicAvailable` is true only on the LAN-direct link AND with `q1` known.
- **`advertise`** — what a side writes into its own stat: `["q1"]` when it can serve the protocol, nothing otherwise. Both sides keep this switched
  off until their QUIC piece exists (Mac: stage 1.6, phone: stage 1.7), so today's `stat` frames are unchanged.

