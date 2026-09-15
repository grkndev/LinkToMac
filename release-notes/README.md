# Release notes

One file per release, named `v<MARKETING_VERSION>.md` — the same version `mac/project.yml` carries.
The file's contents become the **GitHub release body** verbatim.

`mac/scripts/build-release.sh --publish` refuses to publish without the matching file, and checks
before it starts building so a missing one costs you a second rather than a full Release build.
`--no-notes` overrides that and publishes a placeholder body; re-running `--publish` later updates
the body in place, so a typo is a one-line fix and a re-run.

These cover **both apps**, not just the Mac — a release usually ships an Android APK alongside the
DMG. Look at an existing file (or a past release on GitHub) for the shape: what's new, then
"Also fixed", then known limitations, then install instructions for each platform.
