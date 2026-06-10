import type { ReactNode } from 'react';
import { createContext, useContext } from 'react';

import { useClipBoot, type ClipBoot } from './use-clip-boot';

const ClipBootContext = createContext<ClipBoot | null>(null);

/**
 * Hosts the single useClipBoot() instance (autoStart + foreground re-checks) so
 * both the root layout's route guards and the adb-setup route consume the same
 * boot state.
 */
export function ClipBootProvider({ children }: { children: ReactNode }) {
  const boot = useClipBoot();
  return <ClipBootContext.Provider value={boot}>{children}</ClipBootContext.Provider>;
}

export function useClipBootContext(): ClipBoot {
  const ctx = useContext(ClipBootContext);
  if (!ctx) throw new Error('useClipBootContext must be used within a ClipBootProvider');
  return ctx;
}
