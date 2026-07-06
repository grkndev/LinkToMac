import { PairScreen } from '@/features/selfadb/pair-screen';
import { useClipBootContext } from '@/features/selfadb/clip-boot-context';

/**
 * First-run / reconnect gate for the self-ADB pipeline. The root layout routes
 * here while boot isn't 'ready'; PairScreen handles the pair/reconnect modes.
 */
export default function AdbSetupScreen() {
  const boot = useClipBootContext();
  return <PairScreen boot={boot} />;
}
