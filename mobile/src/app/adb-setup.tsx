import { PairScreen } from '@/features/selfadb/pair-screen';
import { useClipBootContext } from '@/features/selfadb/clip-boot-context';

/**
 * Setup screen for automatic clipboard capture (the self-ADB pipeline). Reached from Settings
 * or from the capture banner — never routed to as a gate, so "back" always works. PairScreen
 * handles the live/pair/reconnect modes.
 */
export default function AdbSetupScreen() {
  const boot = useClipBootContext();
  return <PairScreen boot={boot} />;
}
