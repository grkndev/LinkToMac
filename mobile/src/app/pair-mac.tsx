import { useRouter } from 'expo-router';

import { PairMacView } from '@/features/pairing/pair-mac-view';

/** Mac pairing entry (see PairMacView). Shown until a Mac has been paired; Scan opens the QR scanner. */
export default function PairMacScreen() {
  const router = useRouter();
  return <PairMacView onScan={() => router.push('/qr-scan')} />;
}
