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

const NAME = IS_DEV ? 'LinkToMac (Dev)' : 'Link To Mac';
const BUNDLE_ID = IS_DEV ? 'com.grkndev.linktomac.dev' : 'com.grkndev.linktomac';

// User-facing version (the `vX.Y.Z` release tag) and the Android build number.
// `eas.json` sets appVersionSource:"local", so BUILD_NUMBER is authoritative (not the
// EAS remote counter): bump it on every build that ships, and ensure it only ever goes
// UP or a new APK won't install over an older one. CI can override via the env var.
const VERSION = '0.2.1';
const BUILD_NUMBER = Number(process.env.BUILD_NUMBER ?? 3);

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
  },
  updates: {
    url: 'https://u.expo.dev/4fe65b6d-6718-4865-933a-badabf77c68c',
  },
});
