import {
  Box,
  Host,
  LoadingIndicator,
  Shape,
  Surface,
} from "@expo/ui/jetpack-compose";
import { fillMaxSize, size } from "@expo/ui/jetpack-compose/modifiers";
import { StyleSheet, Text, View } from "react-native";

import { useHostTheme, useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";

/** Full-screen spinner badge shown while boot + SecureStore settle (gates the whole Stack). */
export function Booting() {
  const colors = useM3Colors();
  const hostTheme = useHostTheme();
  return (
    <View style={[styles.booting, { backgroundColor: colors.background }]}>
      {/* Fixed-size Host on purpose — matchContents can NPE if this short-lived screen
          unmounts mid-measure. */}
      <Host
        style={{ width: 72, height: 72, backgroundColor: "transparent" }}
        {...hostTheme}
      >
        <Surface
          color={colors.primaryContainer}
          modifiers={[size(72, 72)]}
          shape={Shape.RoundedCorner({
            cornerRadii: {
              bottomEnd: 36,
              topStart: 36,
              bottomStart: 36,
              topEnd: 36,
            },
          })}
        >
          <Box contentAlignment="center" modifiers={[fillMaxSize()]}>
            <LoadingIndicator color={colors.primary} />
          </Box>
        </Surface>
      </Host>
      <Text style={{ fontSize: 16, color: colors.onSurfaceVariant }}>
        Connecting to Mac…
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  booting: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: Spacing.four,
  },
});
