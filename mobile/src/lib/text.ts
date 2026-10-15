/** Cap `text` at `max` characters, appending an ellipsis when cut. */
export function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

/** Collapse whitespace to one line and cap length so list rows stay tidy. */
export function preview(text: string, max: number): string {
  return truncate(text.replace(/\s+/g, ' ').trim(), max);
}

/** `1.2 MB` / `340 KB` / `12 B` — a file size for a list row (binary units, like the system's file manager). */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value >= 10 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/** "now" / "5m" / "2h" / "3d", else a short date. */
export function formatRelative(ts: number): string {
  const diff = Date.now() - ts;
  if (diff < 0) return 'now';
  const min = Math.floor(diff / 60_000);
  if (min < 1) return 'now';
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h`;
  const day = Math.floor(hr / 24);
  if (day < 7) return `${day}d`;
  return new Date(ts).toLocaleDateString();
}
