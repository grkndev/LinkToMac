import { Redirect, useLocalSearchParams } from "expo-router";
import { useEffect, useState } from "react";
import {
  Animated,
  Pressable,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { BootScene, useBootMotion, type Scheme } from "@/components/boot-scene";
import { SplashIntro } from "@/components/splash-intro";
import { PairMacView } from "@/features/pairing/pair-mac-view";

/**
 * DEV ONLY. Replays the first-run experience on demand: `/preview?kind=onboarding | splash | boot`.
 * Reached from Settings ▸ Developer (shown in dev builds only).
 *
 * A preview never navigates away on its own: nothing on these screens is wired to the router (onboarding's
 * Scan button is inert, the boot scene never "finishes"), so the only way out is the back gesture / back
 * button. Release builds redirect straight home, so a deep link can't reach it.
 *
 * It can't use the real routes: `pair-mac` is behind the unpaired guard (Stack.Protected), and the native
 * splash can't be replayed without a cold start — so the splash is replayed in-app from the same generated
 * storyboard (components/splash-intro.tsx).
 */
export default function Preview() {
  if (!__DEV__) return <Redirect href="/" />;
  return <PreviewScreen />;
}

function PreviewScreen() {
  // Not `screen`: that name is reserved by React Navigation (it targets a nested navigator) and never arrives.
  const { kind } = useLocalSearchParams<{ kind?: string }>();
  const scheme: Scheme = useColorScheme() === "dark" ? "dark" : "light";

  switch (kind) {
    case "onboarding":
      return (
        <View style={styles.fill}>
          <PairMacView />
          <Hint text="Onboarding preview · back to exit" />
        </View>
      );
    case "splash":
      return <SplashPreview scheme={scheme} />;
    case "boot":
      return <BootPreview scheme={scheme} />;
    default:
      return <Redirect href="/" />;
  }
}

/** The intro plays once and holds its last frame; tap to replay. */
function SplashPreview({ scheme }: { scheme: Scheme }) {
  const [run, setRun] = useState(0);
  return (
    <Pressable style={styles.fill} onPress={() => setRun((n) => n + 1)}>
      <SplashIntro key={run} scheme={scheme} />
      <Hint text="Splash preview · tap to replay · back to exit" />
    </Pressable>
  );
}

/** The "connecting" frame, looping for as long as you stay. */
function BootPreview({ scheme }: { scheme: Scheme }) {
  const motion = useBootMotion(true);
  return (
    <View style={styles.fill}>
      <BootScene scheme={scheme} motion={motion} />
      <Hint text="Boot preview · back to exit" />
    </View>
  );
}

/** A small pill that tells you how to leave, then fades away so it never sits on the thing being previewed. */
function Hint({ text }: { text: string }) {
  const insets = useSafeAreaInsets();
  const [opacity] = useState(() => new Animated.Value(1));
  useEffect(() => {
    const run = Animated.timing(opacity, {
      toValue: 0,
      duration: 600,
      delay: 2800,
      useNativeDriver: true,
    });
    run.start();
    return () => run.stop();
  }, [opacity]);

  return (
    <View pointerEvents="none" style={[styles.hintWrap, { top: insets.top + 8 }]}>
      <Animated.View style={[styles.hint, { opacity }]}>
        <Text style={styles.hintText}>{text}</Text>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  hintWrap: { position: "absolute", left: 0, right: 0, alignItems: "center" },
  hint: {
    backgroundColor: "rgba(20,20,24,0.82)",
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 16,
  },
  hintText: { color: "#fff", fontSize: 13, fontWeight: "500" },
});
