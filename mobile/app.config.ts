import type { ConfigContext, ExpoConfig } from 'expo/config';

/**
 * Dynamic app config (replaces app.json). The relay endpoint is not baked in: the server address,
 * port, TLS and password come at runtime from the Mac's pairing QR (v2) or Settings -> Relay server
 * (persisted via expo-secure-store; see server-config.ts).
 *
 * Dev vs. prod variant: the development build gets a `.dev` bundle id / package and a distinct name
 * so it can sit on the device next to a release install. Selected via APP_VARIANT (set per profile
 * in eas.json) or EAS_BUILD_PROFILE. Prod values are left untouched so EAS Update keeps targeting
 * existing release installs.
 */
const variant = process.env.APP_VARIANT ?? process.env.EAS_BUILD_PROFILE;
const IS_DEV = variant === 'development';

const NAME = IS_DEV ? 'LinkToMac (Dev)' : 'Link to Mac';
const BUNDLE_ID = IS_DEV ? 'com.grkndev.linktomac.dev' : 'com.grkndev.linktomac';

// User-facing version (the `vX.Y.Z` release tag) and the Android build number.
// `eas.json` sets appVersionSource:"local", so the versionCode is authoritative here
// (not the EAS remote counter).
//
// versionCode is date-based: `YYMMDDNNN` — build date (2-digit year, month, day) followed
// by a 3-digit same-day counter. The first build on 2026-06-22 -> 260622001. The date prefix
// is derived automatically at build time, so each new day's build already outranks the last
// (Android requires versionCode to only ever go UP, or a newer APK won't install over an
// older one). For a 2nd+ build on the SAME day, bump the counter via the BUILD_NUMBER env
// (BUILD_NUMBER=2 -> ...002). Stays under Android's signed 32-bit cap (2,147,483,647): the
// max representable value is 991231999, i.e. it overflows only in the year 2100.
const VERSION = '0.6.1';
const now = new Date();
const DATE_PREFIX =
  (now.getFullYear() % 100) * 10_000 + (now.getMonth() + 1) * 100 + now.getDate();
const BUILD_COUNTER = Number(process.env.BUILD_NUMBER ?? 1); // 1..999, same-day disambiguator
const BUILD_NUMBER = DATE_PREFIX * 1000 + BUILD_COUNTER;

export default (_: ConfigContext): ExpoConfig => ({
  name: NAME,
  slug: 'linktomac',
  version: VERSION,
  // appVersion policy → runtime "0.1.0"; top-level so EAS Update resolves it for every platform.
  runtimeVersion: { policy: 'appVersion' },
  orientation: 'portrait',
  icon: './assets/images/icon.png',
  scheme: 'linktomac',
  userInterfaceStyle: 'automatic',
  ios: {
    icon: './assets/expo.icon',
    bundleIdentifier: BUNDLE_ID,
  },
  android: {
    adaptiveIcon: {
      backgroundColor: '#E6F4FE',
      foregroundImage: './assets/images/android-icon-foreground.png',
      backgroundImage: './assets/images/android-icon-background.png',
      monochromeImage: './assets/images/android-icon-monochrome.png',
    },
    predictiveBackGestureEnabled: false,
    package: BUNDLE_ID,
    versionCode: BUILD_NUMBER,
    permissions: ['android.permission.CAMERA', 'android.permission.RECORD_AUDIO'],
  },
  web: {
    output: 'static',
    favicon: './assets/images/favicon.png',
  },
  plugins: [
    // minSdk 30 = the app's real floor (wireless ADB pairing needs Android 11; ClipCodec's
    // ChaCha20-Poly1305 needs API 28+). Must match the selfadb module's build.gradle minSdk,
    // or the app-level manifest merge fails.
    ['expo-build-properties', { android: { minSdkVersion: 30 } }],
    'expo-router',
    [
      'expo-splash-screen',
      {
        backgroundColor: '#ffffff',
        android: {
          image: './assets/images/splash-icon.png',
          imageWidth: 76,
        },
      },
    ],
    'expo-secure-store',
    [
      'expo-camera',
      {
        cameraPermission: 'Camera access is required to pair with your Mac via QR code.',
        barcodeScannerEnabled: true,
      },
    ],
    'expo-font',
    'expo-image',
    // Raise the Gradle heap so the release dex-merge (D8) doesn't OOM on this RN 0.85 app.
    ['./plugins/with-gradle-heap', { xmx: '4g' }],
  ],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
  extra: {
    router: {},
    eas: {
      projectId: '4fe65b6d-6718-4865-933a-badabf77c68c',
    },
    // Per-variant daemon port: dev and prod installs coexist on one phone, and a shared port
    // means whichever install deploys the daemon last owns it while the other's bridge flaps
    // (rejected/evicted every retry). The native side persists whatever JS passes to
    // autoStart, so this constant is the single source (see features/selfadb/client.ts).
    clipPort: IS_DEV ? 53125 : 53123,
  },
  updates: {
    url: 'https://u.expo.dev/4fe65b6d-6718-4865-933a-badabf77c68c',
  },
});
