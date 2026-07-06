import { useRouter } from 'expo-router';

import { PairScanner } from '@/features/pairing/pair-scanner';
import { usePairing } from '@/features/pairing/pairing-context';

/**
 * Camera QR scanner route. Serves both the first pairing (from pair-mac) and
 * re-pairing (from settings); saving the pairing flips the root guards, and
 * replace('/') lands home in both flows.
 */
export default function QrScanScreen() {
  const { setPairing } = usePairing();
  const router = useRouter();

  return (
    <PairScanner
      onPaired={async ({ pairing, server }) => {
        await setPairing(pairing, server);
        router.replace('/');
      }}
      onCancel={() => router.back()}
    />
  );
}
