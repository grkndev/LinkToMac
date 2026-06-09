import SelfAdb from '../../../modules/selfadb';
import type { AutoStartState } from '../../../modules/selfadb/src/SelfAdb';

/**
 * Localhost port the detached clipboard daemon listens on. MUST match the
 * native `ClipForegroundService.DEFAULT_PORT` (53123).
 */
export const CLIP_PORT = 53123;

export type { AutoStartState };
export default SelfAdb;
