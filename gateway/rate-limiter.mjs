const CLEANUP_INTERVAL_MS = 60 * 1000;

export class RateLimiter {
  #windowMs;
  #maxRequests;
  #clients;
  #cleanupTimer;

  constructor(windowMs, maxRequests) {
    this.#windowMs = windowMs;
    this.#maxRequests = maxRequests;
    this.#clients = new Map();

    this.#cleanupTimer = setInterval(() => this.#cleanup(), CLEANUP_INTERVAL_MS);
    if (this.#cleanupTimer.unref) {
      this.#cleanupTimer.unref();
    }
  }

  check(key) {
    const now = Date.now();
    const entry = this.#clients.get(key);

    if (!entry || now >= entry.resetAt) {
      this.#clients.set(key, { count: 1, resetAt: now + this.#windowMs });
      return true;
    }

    if (entry.count >= this.#maxRequests) {
      return false;
    }

    entry.count += 1;
    return true;
  }

  reset(key) {
    this.#clients.delete(key);
  }

  #cleanup() {
    const now = Date.now();
    for (const [key, entry] of this.#clients) {
      if (now >= entry.resetAt) {
        this.#clients.delete(key);
      }
    }
  }
}

export function getClientIp(request) {
  const forwarded = request.headers['x-forwarded-for'];
  if (forwarded) {
    return forwarded.split(',')[0].trim();
  }

  const realIp = request.headers['x-real-ip'];
  if (realIp) {
    return realIp.trim();
  }

  return request.socket?.remoteAddress ?? '';
}

const FIFTEEN_MINUTES = 15 * 60 * 1000;
const FIVE_MINUTES = 5 * 60 * 1000;
const ONE_HOUR = 60 * 60 * 1000;

export const registerLimiter = new RateLimiter(FIFTEEN_MINUTES, 5);
export const activateLimiter = new RateLimiter(FIVE_MINUTES, 3);
export const challengeLimiter = new RateLimiter(FIFTEEN_MINUTES, 10);
export const verifyLimiter = new RateLimiter(FIFTEEN_MINUTES, 5);
export const refreshLimiter = new RateLimiter(FIFTEEN_MINUTES, 10);
export const reregisterLimiter = new RateLimiter(ONE_HOUR, 3);
