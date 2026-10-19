import { ApiError } from "./errors.js";

interface Bucket { count: number; resetAt: number; }

export class FixedWindowRateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly maximum: number;
  private readonly windowMs: number;
  private readonly maximumBuckets: number;

  constructor(maximum: number, windowMs: number, maximumBuckets = 10_000) {
    this.maximum = maximum;
    this.windowMs = windowMs;
    this.maximumBuckets = maximumBuckets;
  }

  consume(key: string, now = Date.now()): void {
    const existing = this.buckets.get(key);
    const bucket = !existing || existing.resetAt <= now
      ? { count: 0, resetAt: now + this.windowMs }
      : existing;
    if (!existing && this.buckets.size >= this.maximumBuckets) {
      for (const [candidate, value] of this.buckets) if (value.resetAt <= now) this.buckets.delete(candidate);
      if (this.buckets.size >= this.maximumBuckets) throw new ApiError(429, "RATE_LIMITED", "Too many requests; try again later");
    }
    bucket.count += 1;
    this.buckets.set(key, bucket);
    if (bucket.count > this.maximum) throw new ApiError(429, "RATE_LIMITED", "Too many requests; try again later");
  }
}
