cliptest.dex is GENERATED — do not hand-edit.

Build it with:
  ../../../../native-src/cliptest/build-dex.sh
(from the repo: mobile/native-src/cliptest/build-dex.sh)

The script compiles ClipTest.java and drops cliptest.dex here so it ships
inside the dev-client APK as an asset, ready to be pushed to
/data/local/tmp and launched via app_process.
