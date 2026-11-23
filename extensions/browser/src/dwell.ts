/**
 * 3-Layer Effective Dwell Gate:
 * Counts reading time ONLY when ALL THREE signals are simultaneously true:
 *   1. Page Visibility (`document.visibilityState === 'visible'`)
 *   2. Browser Window Focus (`chrome.windows.onFocusChanged !== WINDOW_ID_NONE`)
 *   3. User Activity (`chrome.idle` state === 'active')
 */

export interface DwellSignals {
  pageVisible: boolean;
  windowFocused: boolean;
  userActive: boolean;
}

export class EffectiveDwellTracker {
  private signals: DwellSignals;
  private activeSinceMs: number | null = null;
  private accumulatedMs = 0;
  private firstActiveMs: number | null = null;
  private lastActiveMs: number | null = null;
  private maxScrollDepth = 0;

  constructor(initial: Partial<DwellSignals> = {}, nowMs = Date.now()) {
    this.signals = {
      pageVisible: initial.pageVisible ?? true,
      windowFocused: initial.windowFocused ?? true,
      userActive: initial.userActive ?? true,
    };
    if (this.isAllActive()) {
      this.activeSinceMs = nowMs;
      this.firstActiveMs = nowMs;
      this.lastActiveMs = nowMs;
    }
  }

  isAllActive(): boolean {
    return this.signals.pageVisible && this.signals.windowFocused && this.signals.userActive;
  }

  update(patch: Partial<DwellSignals>, nowMs = Date.now()): number {
    const wasActive = this.isAllActive();
    if (wasActive && this.activeSinceMs !== null && nowMs > this.activeSinceMs) {
      this.accumulatedMs += nowMs - this.activeSinceMs;
      this.lastActiveMs = nowMs;
    }
    this.signals = { ...this.signals, ...patch };
    const nowActive = this.isAllActive();
    if (nowActive) {
      this.activeSinceMs = nowMs;
      if (this.firstActiveMs === null) this.firstActiveMs = nowMs;
      this.lastActiveMs = nowMs;
    } else {
      this.activeSinceMs = null;
    }
    return this.getDwellMs(nowMs);
  }

  recordScrollDepth(ratio: number): void {
    const clamped = Math.max(0, Math.min(1, Number.isFinite(ratio) ? ratio : 0));
    if (clamped > this.maxScrollDepth) {
      this.maxScrollDepth = clamped;
    }
  }

  getScrollDepth(): number {
    return Number(this.maxScrollDepth.toFixed(3));
  }

  getDwellMs(nowMs = Date.now()): number {
    if (this.isAllActive() && this.activeSinceMs !== null && nowMs > this.activeSinceMs) {
      return this.accumulatedMs + (nowMs - this.activeSinceMs);
    }
    return this.accumulatedMs;
  }

  getBounds(nowMs = Date.now()): { tStart: number; tEnd: number } {
    const end = this.isAllActive() ? nowMs : (this.lastActiveMs ?? nowMs);
    const start = this.firstActiveMs ?? Math.max(0, end - this.getDwellMs(nowMs));
    return { tStart: start, tEnd: Math.max(start, end) };
  }

  computeAttention(nowMs = Date.now(), hasExcerpts = false): number {
    const dwellSec = this.getDwellMs(nowMs) / 1000;
    const timeScore = Math.min(1, dwellSec / 180);
    const scrollScore = this.maxScrollDepth;
    const intentBonus = hasExcerpts ? 0.25 : 0;
    return Number(Math.min(1, 0.55 * timeScore + 0.35 * scrollScore + intentBonus).toFixed(3));
  }
}
