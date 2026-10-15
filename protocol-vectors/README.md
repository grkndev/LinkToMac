# Protocol vectors

Shared test vectors for the wire formats that are **mirrored by hand** in two languages. Both codecs must
pass every case, so a change on one side that the other doesn't follow turns a test red instead of
silently breaking sync (the Mac once omitted `id` on one-chunk files while the phone wrote it — every file
under 640 KiB then waited out a 30 s timeout).

| File | Format | Swift | Kotlin |
|---|---|---|---|
| `file-frame.json` | the `file` frame plaintext: `u16 BE header-len ‖ header JSON ‖ raw bytes` | `mac/Tests/FileFrameVectorTests.swift` | `mobile/modules/selfadb/android/src/test/…/FileFrameVectorTest.kt` |

## `file-frame.json`

Each case has a `kind`:

- **`roundtrip`** — `params` is what a sender is asked to build, `header` the header JSON it must produce,
  `frame_hex` a canonical encoding, and `parsed` what a receiver must read back out of it. Each side checks
  *both* directions: `parse(frame_hex) == parsed`, and `encode(params)` yields a frame whose header equals
  `header` and whose body equals `bytes_hex`.
- **`fits`** — an over-long name/directory (`*_repeat` expands to the string). The header must stay inside
  the u16 length prefix, with `dir` shed first and `name` shortened, and the chunk fields and bytes intact.
- **`malformed`** — `frame_hex` must parse to nothing.

Headers are compared as **objects**, not bytes: `JSONSerialization` (Swift) and `org.json` (Kotlin) don't
agree on key order, so byte-equal headers would be impossible and add nothing.

Run them:

```sh
cd mac && xcodegen generate && xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' test
cd mobile/android && ./gradlew :selfadb:testDebugUnitTest
```

When you change the frame format, change the vectors **and both codecs** in the same commit.
