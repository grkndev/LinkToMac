import Constants from 'expo-constants';

import SelfAdb from '../../../modules/selfadb';
import type { AutoStartState } from '../../../modules/selfadb/src/SelfAdb';

/**
 * Localhost port the detached clipboard daemon listens on. Per-variant (dev 53125 /
 * prod 53123, set in app.config.ts `extra.clipPort`) so two installs on one phone never
 * fight over a single daemon. The native side persists whatever autoStart passes
 * (ClipForegroundService KEY_CLIP_PORT), falling back to its DEFAULT_PORT (53123).
 */
export const CLIP_PORT: number = Constants.expoConfig?.extra?.clipPort ?? 53123;

export type { AutoStartState };
// Re-export the native event payload types so feature code never reaches into
// modules/selfadb with deep relative paths.
export type {
  ClipEvent,
  LogEvent,
  RelayEvent,
  StatEvent,
  StatusEvent,
} from '../../../modules/selfadb/src/SelfAdb.types';
export default SelfAdb;
