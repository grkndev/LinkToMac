import { Column, Host } from "@expo/ui/jetpack-compose";
import {
  fillMaxWidth,
  padding,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import type { ReactNode } from "react";
import { useColorScheme } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { SEED, useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";

/** The app-wide Compose root: a full-screen seeded Host painted with the M3 background. */
export function M3Host({ children }: { children: ReactNode }) {
  const scheme = useColorScheme();
  const colors = useM3Colors();
  return (
    <Host
      style={{ flex: 1, backgroundColor: colors.background }}
      seedColor={SEED}
      colorScheme={scheme}
    >
      {children}
    </Host>
  );
}

/**
 * The standard scrolling screen body shared by Home, Settings, About & co: an {@link M3Host}
 * with a full-width vertically-scrolling Column, Spacing.three side padding and the bottom
 * inset absorbed. A plain Column (not LazyColumn) on purpose — verticalScroll() passes
 * infinite height constraints that crash a LazyColumn.
 */
export function M3Screen({
  children,
  safeTop = false,
  paddingTop = Spacing.two,
  spacing,
}: {
  children: ReactNode;
  /** add the top safe-area inset (headerless screens like Home). */
  safeTop?: boolean;
  paddingTop?: number;
  /** vertical `spacedBy` between the Column's children. */
  spacing?: number;
}) {
  const insets = useSafeAreaInsets();
  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxWidth(),
          verticalScroll(),
          padding(
            Spacing.three,
            (safeTop ? insets.top : 0) + paddingTop,
            Spacing.three,
            insets.bottom + Spacing.five,
          ),
        ]}
        verticalArrangement={spacing != null ? { spacedBy: spacing } : undefined}
      >
        {children}
      </Column>
    </M3Host>
  );
}
