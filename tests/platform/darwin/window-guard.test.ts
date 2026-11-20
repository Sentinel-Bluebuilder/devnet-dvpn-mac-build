// ─── Mac rc.2 reboot 1: a start-up window whose page never loaded stayed blank until Cmd+R ───
// DIR 11-13: on the start-up show, reload once when the page has not loaded/drawn within ~5 s or the renderer is gone
// or unresponsive, and log it. These drive system/window-guard.ts with a fake window.
import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ensurePageShown, trackPage, resetPageGuardForTests, PAGE_PROBE_MS, PAGE_DRAWN_JS, type GuardWindow } from '../../../src/main/system/window-guard';

type Fn = () => void;
function fakeWindow(opts: { drawn?: unknown; answer?: boolean; crashed?: boolean } = {}) {
  const wc: Record<string, Fn[]> = {};
  const wn: Record<string, Fn[]> = {};
  const reload = vi.fn();
  const w = {
    destroyed: false,
    isDestroyed() { return this.destroyed; },
    on(e: string, fn: Fn) { (wn[e] ??= []).push(fn); return this; },
    webContents: {
      on(e: string, fn: Fn) { (wc[e] ??= []).push(fn); return this; },
      isCrashed: () => !!opts.crashed,
      executeJavaScript: vi.fn((code: string) => {
        expect(code).toBe(PAGE_DRAWN_JS);
        return opts.answer === false ? new Promise(() => {}) : Promise.resolve(opts.drawn ?? true);
      }),
      reload,
    },
  };
  const fire = (src: 'wc' | 'win', e: string): void => { for (const f of (src === 'wc' ? wc : wn)[e] ?? []) f(); };
  return { w: w as unknown as GuardWindow & { destroyed: boolean }, reload, fire, js: w.webContents.executeJavaScript };
}
// The guard delay passes at once; the renderer-answer timeout passes only when asked to.
const waitNoProbeTimeout = (ms: number): Promise<void> => (ms === PAGE_PROBE_MS ? new Promise(() => {}) : Promise.resolve());
const waitAll = (): Promise<void> => Promise.resolve();

beforeEach(() => resetPageGuardForTests());

describe('start-up window page guard', () => {
  it('loaded and drawn: nothing to do', async () => {
    const f = fakeWindow({ drawn: true });
    trackPage(f.w); f.fire('wc', 'did-finish-load');
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('ok');
    expect(f.reload).not.toHaveBeenCalled();
  });

  it('the page never loaded (reboot 1): reloads once', async () => {
    const f = fakeWindow();
    trackPage(f.w);
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('reloaded');
    expect(f.reload).toHaveBeenCalledTimes(1);
    expect(f.js).not.toHaveBeenCalled();
  });

  it('loaded but nothing drawn in #root: reloads', async () => {
    const f = fakeWindow({ drawn: false });
    trackPage(f.w); f.fire('wc', 'did-finish-load');
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('reloaded');
  });

  it('the renderer does not answer: counts as not drawn and reloads', async () => {
    const f = fakeWindow({ answer: false });
    trackPage(f.w); f.fire('wc', 'did-finish-load');
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitAll)).toBe('reloaded');
  });

  it('renderer gone, crashed or unresponsive: reloads', async () => {
    for (const how of ['gone', 'crashed', 'unresponsive'] as const) {
      resetPageGuardForTests();
      const f = fakeWindow({ crashed: how === 'crashed' });
      trackPage(f.w); f.fire('wc', 'did-finish-load');
      if (how === 'gone') f.fire('wc', 'render-process-gone');
      if (how === 'unresponsive') f.fire('win', 'unresponsive');
      expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('reloaded');
      expect(f.reload).toHaveBeenCalledTimes(1);
    }
  });

  it('reloads at most once per app run', async () => {
    const f = fakeWindow();
    trackPage(f.w);
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('reloaded');
    expect(await ensurePageShown(f.w, 'second launch', 5000, waitNoProbeTimeout)).toBe('skipped');
    expect(f.reload).toHaveBeenCalledTimes(1);
  });

  it('negative control: a closed window is left alone', async () => {
    const f = fakeWindow();
    trackPage(f.w); f.w.destroyed = true;
    expect(await ensurePageShown(f.w, 'block at start', 5000, waitNoProbeTimeout)).toBe('skipped');
    expect(f.reload).not.toHaveBeenCalled();
  });

  it('index.ts tracks every window and guards both start-up shows', () => {
    const main = readFileSync('src/main/index.ts', 'utf8');
    expect(main).toContain('trackPage(w);');
    expect(main.indexOf('trackPage(w);')).toBeLessThan(main.indexOf('void w.loadFile('));
    expect(main).toContain("void ensurePageShown(win, 'block at start');");
    expect(main).toContain("void ensurePageShown(win, 'second launch');");
  });
});
