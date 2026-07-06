import { useM3Colors } from '@/components/m3';
import { StatusColors } from '@/constants/theme';
import type { RelayUi } from './use-relay-status';

/** How many failed reconnect attempts before the UI gives up and shows "Disconnected".
 *  The link keeps retrying in the background regardless; this is purely the label threshold. */
const RECONNECT_LIMIT = 3;

export type ConnectionState = 'connected' | 'connecting' | 'reconnecting' | 'disconnected';

export type ConnectionStatus = {
  connected: boolean;
  state: ConnectionState;
  /** "Connected" / "Connecting…" / "Reconnecting…" / "Disconnected" */
  label: string;
  /** status-dot color for the current state */
  color: string;
  /** how the link is carried: "LAN" | "Relay" | null when down / unknown */
  transportLabel: string | null;
};

/** Derives Home's human-readable connection status from the raw relay state. */
export function useConnectionStatus(relay: RelayUi): ConnectionStatus {
  const colors = useM3Colors();

  const connected = relay.peerOnline;
  // The link auto-reconnects with backoff; show "Reconnecting" while it's actively retrying, and
  // only fall back to "Disconnected" once it's tried RECONNECT_LIMIT times (or hit a dead end).
  const retrying =
    !connected && (relay.status === 'connecting' || relay.status === 'connected');
  const attempt = relay.attempt ?? 0;
  const state: ConnectionState = connected
    ? 'connected'
    : retrying && attempt < RECONNECT_LIMIT
      ? attempt === 0
        ? 'connecting'
        : 'reconnecting'
      : 'disconnected';

  const label =
    state === 'connected'
      ? 'Connected'
      : state === 'connecting'
        ? 'Connecting…'
        : state === 'reconnecting'
          ? 'Reconnecting…'
          : 'Disconnected';
  const color =
    state === 'connected'
      ? StatusColors.online
      : state === 'disconnected'
        ? colors.error
        : StatusColors.warn;
  // Only meaningful while connected.
  const transportLabel =
    relay.transport === 'lan' ? 'LAN' : relay.transport === 'relay' ? 'Relay' : null;

  return { connected, state, label, color, transportLabel };
}
