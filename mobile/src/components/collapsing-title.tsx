import { useNavigation } from "expo-router";
import { useCallback, useLayoutEffect, useState } from "react";
import { Animated, Easing } from "react-native";

import { useM3Colors } from "@/components/m3";
import { SANS } from "@/constants/typography";

/**
 * Collapsing large title for screens that draw a `LargeTitle` in the body under a title-less native
 * header (Settings, Notifications): once the big title has scrolled mostly out of view, the same
 * text slides + fades into the header, next to the back arrow.
 *
 * Compose gives us no scroll offset, but `onVisibilityChanged` fires when the title leaves/enters
 * the viewport — so the trigger is binary (not scrubbed with the finger) and the slide itself is an
 * RN `Animated` timing on the native driver. The header title is set ONCE through `setOptions` and
 * driven by an `Animated.Value`, so toggling never re-renders it (a re-created `headerTitle`
 * function would remount and restart the animation).
 *
 * Pass the returned handler to `<LargeTitle onVisibleChange={…}>`.
 */
export function useCollapsingTitle(title: string): (visible: boolean) => void {
  const navigation = useNavigation();
  const colors = useM3Colors();
  const [progress] = useState(() => new Animated.Value(0));

  useLayoutEffect(() => {
    navigation.setOptions({
      headerTitle: () => (
        <Animated.Text
          numberOfLines={1}
          style={{
            color: colors.onSurface,
            fontFamily: SANS.regular,
            fontSize: 22,
            opacity: progress,
            transform: [
              { translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [14, 0] }) },
            ],
          }}
        >
          {title}
        </Animated.Text>
      ),
    });
  }, [navigation, progress, title, colors.onSurface]);

  return useCallback(
    (visible: boolean) => {
      Animated.timing(progress, {
        toValue: visible ? 0 : 1,
        duration: 200,
        easing: Easing.out(Easing.cubic),
        useNativeDriver: true,
      }).start();
    },
    [progress],
  );
}
