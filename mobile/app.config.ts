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

export default (_: ConfigContext): ExpoConfig => ({
  name: NAME,
  slug: 'linktomac',
  version: '0.1.0',
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
