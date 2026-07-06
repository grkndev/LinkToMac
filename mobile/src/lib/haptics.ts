import * as Haptics from 'expo-haptics';

/** The house tap feedback: a medium impact, errors swallowed (haptics are best-effort). */
export function haptic(): void {
  Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
}
