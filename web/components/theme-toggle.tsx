"use client";

import { useTheme } from "next-themes";
import { MoonIcon, SunIcon } from "./icons";

/* Icon-only theme switch, styled like the nav's GitHub button. The two icons
   swap via the `dark` class so no mount guard is needed — the server render
   matches whatever class the next-themes script sets before paint. */
export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();

  return (
    <button
      type="button"
      aria-label="Toggle dark mode"
      onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
      className="flex size-10 cursor-pointer items-center justify-center rounded-full text-fg-2 transition-colors duration-200 hover:bg-surface-2 hover:text-fg"
    >
      <MoonIcon className="size-5 dark:hidden" />
      <SunIcon className="hidden size-5 dark:block" />
    </button>
  );
}
