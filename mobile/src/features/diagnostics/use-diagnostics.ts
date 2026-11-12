import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Updates from 'expo-updates';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { usePairing } from '@/features/pairing/pairing-context';
import { useClipBootContext } from '@/features/selfadb/clip-boot-context';
import SelfAdb from '@/features/selfadb/client';
import { withTimeout } from '@/lib/async';

import {
  buildReport,
  type ExitRecord,
  type Granted,
  type Report,
  type ReportData,
} from './build-report';
import { useKnownValues } from './use-known-values';

/** Native probes answer from memory or a settings read; a few seconds is generous. */
const PROBE_MS = 4_000;
/** The daemon log falls back to an adb `tail` when the bridge is down, which can stall. */
const DAEMON_LOG_MS = 15_000;
const EXIT_REASON_LIMIT = 10;

/** Runs a probe with a deadline; a failure or timeout is `null` ("unknown"), never a thrown error. */
async function probe<T>(run: () => Promise<T>, ms = PROBE_MS): Promise<T | null> {
  try {
    return await withTimeout(run(), ms, 'diagnostics probe');
  } catch {
    return null;
  }
}

/**
 * `getExitReasons` only exists in APKs built after the diagnostics work. An OTA of this JS onto an
 * older APK has to skip the section instead of throwing, hence the feature check (same pattern as
 * `getAutoUpdate` in settings).
 */
async function readExits(): Promise<ExitRecord[] | 'unsupported' | null> {
  if (typeof SelfAdb.getExitReasons !== 'function') return 'unsupported';
  return probe(() => SelfAdb.getExitReasons(EXIT_REASON_LIMIT));
}

const PERMISSIONS: { name: string; check: () => Promise<boolean> }[] = [
  { name: 'Notifications', check: () => SelfAdb.hasPostNotifications() },
  { name: 'Notification access', check: () => SelfAdb.hasNotificationAccess() },
  { name: 'SMS read + contacts', check: () => SelfAdb.hasSmsAccess() },
  { name: 'SMS send', check: () => SelfAdb.hasSendSmsAccess() },
  { name: 'Nearby devices', check: () => SelfAdb.hasNearbyDevicesPermission() },
  { name: 'Battery optimization ignored', check: () => SelfAdb.hasIgnoreBatteryOptimizations() },
  { name: 'WRITE_SECURE_SETTINGS', check: () => SelfAdb.hasSecureSettings() },
];

export type Diagnostics = {
  /** null until the first collection finishes. */
  report: Report | null;
  /** true while (re)collecting; the Share / issue buttons stay disabled meanwhile. */
  busy: boolean;
  refresh: () => void;
};

/**
 * Collects everything the report needs, on this device, once when the screen opens and again on
 * `refresh`. Nothing here talks to the network and nothing is sent anywhere: the result is a
 * string the person reads and then chooses to share.
 */
export function useDiagnostics(): Diagnostics {
  const { pairing, server } = usePairing();
  const boot = useClipBootContext();
  const known = useKnownValues();
  const [data, setData] = useState<ReportData | null>(null);
  const [busy, setBusy] = useState(true);
  // Bumped by `refresh`; each value is one collection run (see the effect below).
  const [round, setRound] = useState(0);
  // The latest values, read when a collection finishes without re-triggering it on every change.
  const live = useRef({ pairing, server, boot });
  useEffect(() => {
    live.current = { pairing, server, boot };
  });

  const collect = useCallback(async (): Promise<ReportData> => {
    const [relay, daemonAlive, update, exits, daemonBlob, appLog, ...granted] = await Promise.all([
      probe(() => SelfAdb.relayGetStatus()),
      probe(() => SelfAdb.isDaemonAlive()),
      probe(() => SelfAdb.getAppUpdateState()),
      readExits(),
      probe(() => SelfAdb.readDaemonLog(), DAEMON_LOG_MS),
      probe(() => SelfAdb.getLogs()),
      ...PERMISSIONS.map((p) => probe(p.check) as Promise<Granted>),
    ]);
    const { pairing: p, server: s, boot: b } = live.current;
    return {
      generatedAt: new Date(),
      app: {
        version: Constants.expoConfig?.version ?? '—',
        versionCode: Constants.expoConfig?.android?.versionCode ?? null,
        packageName: Constants.expoConfig?.android?.package ?? null,
        channel: Updates.channel ?? null,
        runtimeVersion: Updates.runtimeVersion ?? null,
        updateId: Updates.updateId ?? null,
        embedded: Updates.isEnabled ? Updates.isEmbeddedLaunch : null,
        devBundle: __DEV__,
        updatesEnabled: Updates.isEnabled,
      },
      device: {
        manufacturer: Device.manufacturer,
        model: Device.modelName,
        osVersion: Device.osVersion,
        apiLevel: Device.platformApiLevel,
      },
      status: {
        paired: !!p,
        relayConfigured: !!s?.host,
        lanEnabled: s ? s.lanEnabled ?? true : null,
        relay: relay
          ? {
              status: relay.status,
              transport: relay.transport ?? null,
              peerOnline: relay.peerOnline,
              attempt: relay.attempt ?? null,
              lastError: relay.lastError ?? null,
            }
          : null,
        capture: { state: b.state, reason: b.reason, error: b.error },
        daemonAlive,
      },
      permissions: PERMISSIONS.map((perm, i) => ({ name: perm.name, granted: granted[i] ?? null })),
      update: update ? { state: update.state, version: update.version, error: update.error } : null,
      exits,
      daemonLog: daemonBlob === null ? null : daemonBlob.split('\n'),
      appLog,
    };
  }, []);

  // One collection per `round`. State is set only from the async continuation, and a run that is
  // superseded (Refresh tapped again) or abandoned (screen closed) drops its result.
  useEffect(() => {
    let cancelled = false;
    collect().then((next) => {
      if (cancelled) return;
      setData(next);
      setBusy(false);
    });
    return () => {
      cancelled = true;
    };
  }, [collect, round]);

  const refresh = useCallback(() => {
    setBusy(true);
    setRound((r) => r + 1);
  }, []);

  // Sanitizing is the last step, so a change to the known values re-sanitizes without re-collecting.
  const report = useMemo(() => (data ? buildReport(data, known) : null), [data, known]);

  return { report, busy, refresh };
}
