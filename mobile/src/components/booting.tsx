import {
  Box,
  Host,
  LoadingIndicator,
  Shape,
  Surface,
} from "@expo/ui/jetpack-compose";
import { fillMaxSize, size } from "@expo/ui/jetpack-compose/modifiers";
import { StyleSheet, useColorScheme } from "react-native";

import { SEED, useM3Colors } from "@/components/m3";
import { ThemedText } from "@/components/themed-text";
import { ThemedView } from "@/components/themed-view";
import { Spacing } from "@/constants/theme";

/** Full-screen spinner badge shown while boot + SecureStore settle (gates the whole Stack). */
export function Booting() {
  const colors = useM3Colors();
  const scheme = useColorScheme();
  return (
    <ThemedView
      style={[styles.booting, { backgroundColor: colors.background }]}
    >
      {/* Fixed-size Host on purpose — matchContents can NPE if this short-lived screen
          unmounts mid-measure. */}
      <Host
        style={{ width: 64, height: 64, backgroundColor: "transparent" }}
        seedColor={SEED}
        colorScheme={scheme}
      >
        <Surface
          color={colors.secondaryContainer}
          modifiers={[size(64, 64)]}
          shape={Shape.RoundedCorner({
            cornerRadii: {
              bottomEnd: 32,
              topStart: 32,
              bottomStart: 32,
              topEnd: 32,
            },
          })}
        >
          <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
            <LoadingIndicator color={colors.primary} />
          </Box>
        </Surface>
      </Host>
      <ThemedText type="default" themeColor="textSecondary">
        Connecting to Mac...
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  booting: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: Spacing.three,
  },
});
