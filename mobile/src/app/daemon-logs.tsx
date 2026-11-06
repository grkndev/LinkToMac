import { Column, Icon, Row, Surface, Shape, } from '@expo/ui/jetpack-compose';
import { Text } from "@/components/text";
import { fillMaxSize, fillMaxWidth, padding, weight } from '@expo/ui/jetpack-compose/modifiers';
import { useCallback, useEffect, useState } from 'react';
import { Share } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ToolButton } from '@/components/buttons';
import { useIcons } from '@/components/icons';
import { LogView } from '@/components/log-view';
import { useM3Colors } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { Spacing } from '@/constants/theme';
import SelfAdb, { CLIP_PORT } from '@/features/selfadb/client';
import { TimeoutError, withTimeout } from '@/lib/async';

// JS-side backstops. The native calls are now internally bounded (libadb connect is capped and
// a busy op returns immediately), so these only fire if something unforeseen wedges — without
// them a stuck promise would spin the button forever (its .finally never runs).
const READ_LOG_TIMEOUT_MS = 25_000;
const RESTART_TIMEOUT_MS = 40_000; // discover + connect + relaunch + bind, all bounded, summed

function describeError(e: unknown): string {
  if (e instanceof TimeoutError) return 'Timed out — is Wireless debugging on? Tap to try again.';
  return (e as { message?: string })?.message ?? String(e);
}

/**
 * The privileged clipboard daemon's OWN on-device log — the ground truth for whether the shell
 * agent is alive, its system context built, and the clip-changed listener is capturing.
 *
 * Read over the localhost bridge (no adb, so it can't hit libadb's BufferOverflowException); the
 * daemon stamps each line with its own HH:mm:ss when it writes it (the whole buffer is fetched at
 * once, so the app can't time individual lines). "Restart" reloads a rebuilt dex without a reboot.
 */
export default function DaemonLogsScreen() {
  const colors = useM3Colors();
  const icons = useIcons();
  const insets = useSafeAreaInsets();
  const [text, setText] = useState<string | null>(null);
  const [fetching, setFetching] = useState(false);
  const [restarting, setRestarting] = useState(false);

  const fetchLog = useCallback(() => {
    setFetching(true);
    withTimeout(SelfAdb.readDaemonLog(), READ_LOG_TIMEOUT_MS, 'readDaemonLog')
      .then(setText)
      .catch((e: unknown) => setText(`Error: ${describeError(e)}`))
      .finally(() => setFetching(false));
  }, []);

  // Pull once on open (state is only set from the async callbacks, never synchronously here).
  useEffect(() => {
    let alive = true;
    withTimeout(SelfAdb.readDaemonLog(), READ_LOG_TIMEOUT_MS, 'readDaemonLog')
      .then((blob) => alive && setText(blob))
      .catch((e: unknown) => alive && setText(`Error: ${describeError(e)}`));
    return () => {
      alive = false;
    };
  }, []);

  const restartDaemon = useCallback(() => {
    setRestarting(true);
    withTimeout(SelfAdb.restartDaemon(CLIP_PORT), RESTART_TIMEOUT_MS, 'restartDaemon')
      .then((msg) => setText(`${msg}\n\n(Tap Refresh to pull the new daemon log.)`))
      .catch((e: unknown) => setText(`Restart error: ${describeError(e)}`))
      .finally(() => setRestarting(false));
  }, []);

  const shareAll = useCallback(() => {
    Share.share({ message: text ?? '' }).catch(() => {});
  }, [text]);

  // An error/timeout lands in `text` as "Error: …" / "Restart error: …" — show it as a banner
  // (tap = try again) rather than as a log line.
  const failure = text && /^(Restart error|Error): /.test(text) ? text.replace(/^(Restart error|Error): /, '') : null;
  const lines = failure || !text ? [] : text.split('\n');

  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxSize(),
          padding(Spacing.three, Spacing.one, Spacing.three, insets.bottom + Spacing.three),
        ]}
        verticalArrangement={{ spacedBy: 12 }}
      >
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: Spacing.two }}>
          <ToolButton colors={colors} icon={icons.retry} label="Refresh" grow busy={fetching} onPress={fetchLog} />
          <ToolButton
            colors={colors}
            icon={icons.restartAlt}
            label="Restart"
            grow
            busy={restarting}
            onPress={restartDaemon}
          />
          <ToolButton colors={colors} icon={icons.share} tone="neutral" onPress={shareAll} />
        </Row>
        {failure ? (
          <Surface
            color={colors.errorContainer}
            shape={Shape.RoundedCorner({
              cornerRadii: { topStart: 20, topEnd: 20, bottomStart: 20, bottomEnd: 20 },
            })}
            onClick={fetchLog}
            modifiers={[fillMaxWidth()]}
          >
            <Row
              modifiers={[fillMaxWidth(), padding(16, 14, 16, 14)]}
              horizontalArrangement={{ spacedBy: 12 }}
              verticalAlignment="top"
            >
              <Icon source={icons.error} size={20} tint={colors.onErrorContainer} />
              <Text modifiers={[weight(1)]} color={colors.onErrorContainer} style={{ typography: 'bodyMedium' }}>
                {failure}
              </Text>
            </Row>
          </Surface>
        ) : null}
        <Column modifiers={[fillMaxWidth(), weight(1)]}>
          <LogView
            colors={colors}
            lines={lines}
            empty={fetching ? 'Fetching daemon log…' : 'No daemon log.'}
          />
        </Column>
      </Column>
    </M3Host>
  );
}
