import * as Device from 'expo-device';
import { useMemo } from 'react';

import { usePairing } from '@/features/pairing/pairing-context';

import { knownValuesFrom, type KnownValues } from './sanitize';

/**
 * The device-specific strings the sanitizer must scrub wherever they appear: the Mac's name, this
 * phone's name, the relay host and the pairing secrets. Memoised so a screen can hand it straight
 * to `sanitizeLines` in a `useMemo` without recompiling on every render.
 */
export function useKnownValues(): KnownValues {
  const { pairing, server } = usePairing();
  const deviceName = Device.deviceName;
  return useMemo(() => knownValuesFrom({ pairing, server, deviceName }), [pairing, server, deviceName]);
}
