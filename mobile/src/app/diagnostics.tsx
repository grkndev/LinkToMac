import { Column, Row } from '@expo/ui/jetpack-compose';
import { fillMaxSize, fillMaxWidth, padding, weight } from '@expo/ui/jetpack-compose/modifiers';
import { Linking, Share } from 'react-native';
import { useCallback } from 'react';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ToolButton } from '@/components/buttons';
import { useIcons } from '@/components/icons';
import { LogView } from '@/components/log-view';
import { useM3Colors } from '@/components/m3';
import { M3Host } from '@/components/m3-screen';
import { InlineNotice } from '@/components/rows';
import { Spacing } from '@/constants/theme';
import { issueUrl } from '@/features/diagnostics/build-report';
import { useDiagnostics } from '@/features/diagnostics/use-diagnostics';

/**
 * Send diagnostics: builds a bug report ON THIS DEVICE, shows exactly what it contains, and lets the
 * person choose to share it (Android's share sheet) or open a pre-filled GitHub issue.
 *
 * Nothing is sent automatically and there is no telemetry — the report is just a string until a
 * button is tapped. The preview is the very `report.text` that Share sends, so what you read is
 * what goes. It is deliberately NOT copied to the clipboard: the app's own clipboard sync would
 * forward it to the Mac and write it into the clip history.
 */
export default function DiagnosticsScreen() {
  const colors = useM3Colors();
  const icons = useIcons();
  const insets = useSafeAreaInsets();
  const { report, busy, refresh } = useDiagnostics();

  const share = useCallback(() => {
    if (!report) return;
    Share.share({ message: report.text, title: 'Link to Mac diagnostics' }).catch(() => {});
  }, [report]);

  const openIssue = useCallback(() => {
    if (!report) return;
    Linking.openURL(issueUrl(report.summary)).catch(() => {});
  }, [report]);

  const ready = !!report && !busy;

  return (
    <M3Host>
      <Column
        modifiers={[
          fillMaxSize(),
          padding(Spacing.three, Spacing.one, Spacing.three, insets.bottom + Spacing.three),
        ]}
        verticalArrangement={{ spacedBy: 12 }}
      >
        <InlineNotice
          colors={colors}
          tone="tertiary"
          icon={icons.gppMaybe}
          title="Prepared on this device"
          message="Nothing is sent automatically. Clipboard text, file names, addresses and device names are removed. GitHub issues are public, so read the report below before you share it."
        />
        <Column modifiers={[fillMaxWidth(), weight(1)]}>
          <LogView
            colors={colors}
            lines={report?.lines ?? []}
            empty={busy ? 'Preparing report…' : 'No report.'}
          />
        </Column>
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: Spacing.two }}>
          <ToolButton
            colors={colors}
            icon={icons.share}
            label="Share report"
            grow
            onPress={ready ? share : () => {}}
          />
          <ToolButton
            colors={colors}
            icon={icons.openInNew}
            label="GitHub issue"
            tone="neutral"
            grow
            onPress={ready ? openIssue : () => {}}
          />
          <ToolButton colors={colors} icon={icons.retry} tone="neutral" busy={busy} onPress={refresh} />
        </Row>
      </Column>
    </M3Host>
  );
}
