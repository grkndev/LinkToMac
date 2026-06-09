/** Per-connection sliding-window rate limiter. */
export class SlidingWindowLimiter {
  private readonly hits: number[] = [];

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  /** Records an event. Returns true if allowed, false if the window limit is exceeded. */
  hit(now = Date.now()): boolean {
    const cutoff = now - this.windowMs;
    // Drop timestamps that fell out of the window.
    while (this.hits.length > 0) {
      const first = this.hits[0];
      if (first === undefined || first > cutoff) break;
      this.hits.shift();
    }
    if (this.hits.length >= this.max) return false;
    this.hits.push(now);
    return true;
  }
}
