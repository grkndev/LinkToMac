# Protocol vectors

Shared test vectors for the wire formats that are **mirrored by hand** in two languages. Both codecs must
pass every case, so a change on one side that the other doesn't follow turns a test red instead of
silently breaking sync (the Mac once omitted `id` on one-chunk files while the phone wrote it — every file
under 640 KiB then waited out a 30 s timeout).

| File | Format | Swift | Kotlin |
|---|---|---|---|
| `file-frame.json` | the `file` frame plaintext: `u16 BE header-len ‖ header JSON ‖ raw bytes` | `mac/Tests/FileFrameVectorTests.swift` | `mobile/modules/selfadb/android/src/test/…/FileFrameVectorTest.kt` |
| `dir-sanitize.json` | how a peer-supplied `dir` (folder path) is made safe to write under the download folder | `FileFrameVectorTests.dirSanitizeVectors` (→ `FileDropStore.sanitizeDir`) | `FileFrameVectorTest.dirSanitizeVectors` (→ `FileSink.sanitizeDir`) |

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
