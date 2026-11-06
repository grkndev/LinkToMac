import { Box, LazyColumn, Row, type MaterialColors } from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import { fillMaxSize, fillMaxWidth, padding, weight, background, clip, Shapes } from "@expo/ui/jetpack-compose/modifiers";

import { StatusColors } from "@/constants/theme";

/** Matches the `HH:mm:ss` (optionally `.mmm`) stamp a log line may start with. */
const STAMP = /^(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.*)$/s;

/** Tint a few high-signal lines so failures/successes stand out while scanning. */
export function lineTone(line: string, colors: MaterialColors): string {
  const l = line.toLowerCase();
  if (
    l.includes("error") ||
    l.includes("hata") ||
    l.includes("fail") ||
    l.includes("exception") ||
    l.includes("retry")
  ) {
    return colors.error;
  }
  if (
    l.includes("clip ⬆") ||
    l.includes("-> clipboard") ||
    l.includes("captured") ||
    l.includes("context ready") ||
    l.includes("-> emit") ||
    l.includes("-> mac")
  ) {
    return StatusColors.online;
  }
  return colors.onSurfaceVariant;
}

/**
 * The monospace log pane shared by Logs and Daemon log: a rounded surface holding a virtualized
 * list (a LazyColumn — this lives OUTSIDE any verticalScroll so its height is bounded, which is
 * what a LazyColumn needs). Each line dims its timestamp and tints errors/successes.
 */
export function LogView({
  colors,
  lines,
  empty,
}: {
  colors: MaterialColors;
  lines: string[];
  empty: string;
}) {
  return (
    <Box
      modifiers={[
        fillMaxSize(),
        clip(Shapes.RoundedCorner(20)),
        background(colors.surfaceContainerLow),
      ]}
    >
      {lines.length === 0 ? (
        <Box modifiers={[fillMaxWidth(), padding(14, 14, 14, 14)]}>
          <Text color={colors.onSurfaceVariant} style={{ fontSize: 11, lineHeight: 18, fontFamily: "monospace" }}>
            {empty}
          </Text>
        </Box>
      ) : (
        <LazyColumn modifiers={[fillMaxSize()]} contentPadding={{ start: 14, end: 14, top: 14, bottom: 14 }}>
          {lines.map((line, i) => {
            const m = STAMP.exec(line);
            const tone = lineTone(line, colors);
            return (
              <Row key={i} modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: 8 }} verticalAlignment="top">
                {m ? (
                  <Text color={colors.onSurfaceVariant} style={{ fontSize: 11, lineHeight: 18, fontFamily: "monospace" }}>
                    {m[1]}
                  </Text>
                ) : null}
                <Text
                  modifiers={[weight(1)]}
                  color={tone}
                  style={{ fontSize: 11, lineHeight: 18, fontFamily: "monospace" }}
                >
                  {m ? m[2] : line || " "}
                </Text>
              </Row>
            );
          })}
        </LazyColumn>
      )}
    </Box>
  );
}
