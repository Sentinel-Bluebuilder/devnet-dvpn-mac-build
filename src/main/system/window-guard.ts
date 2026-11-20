// ─── A window brought up at start shows its page (Agent M, Mac 0.3.0-rc.2 reboot 1) ───
// After a restart with the kill switch on, the app (started at log-in by its LaunchAgent) found the block and showed
// its window, but the page had never loaded (renderer 38 MB, no React tree): a blank window over a blocked internet
// until Cmd+R, the exact thing the owner decided against (DIR 11-13). On every show at start-up: when the page has not
// finished loading within PAGE_GUARD_MS, has no rendered tree, or the renderer is gone or unresponsive, reload it
// once, and log what was seen either way.
import { log } from '../logger';

export const PAGE_GUARD_MS = 5_000;
/** How long the renderer gets to answer "is the page drawn?" before it counts as not drawn. */
export const PAGE_PROBE_MS = 2_000;
/** True when the React root has content (src/renderer/index.html `#root`). */
export const PAGE_DRAWN_JS = "!!(document.getElementById('root') && document.getElementById('root').childElementCount > 0)";

export interface GuardWebContents {
  on(event: 'did-finish-load' | 'render-process-gone', fn: () => void): unknown;
  isCrashed(): boolean;
  executeJavaScript(code: string): Promise<unknown>;
  reload(): void;
}
export interface GuardWindow {
  isDestroyed(): boolean;
  on(event: 'unresponsive' | 'responsive', fn: () => void): unknown;
  webContents: GuardWebContents;
}

interface PageState { loaded: boolean; gone: boolean; unresponsive: boolean }
const states = new WeakMap<GuardWindow, PageState>();
let reloadedOnce = false;

/** Follow the window's page from creation (call before its loadFile). */
export function trackPage(w: GuardWindow): void {
  const s: PageState = { loaded: false, gone: false, unresponsive: false };
  states.set(w, s);
  w.webContents.on('did-finish-load', () => { s.loaded = true; s.gone = false; });
  w.webContents.on('render-process-gone', () => { s.gone = true; s.loaded = false; });
  w.on('unresponsive', () => { s.unresponsive = true; });
  w.on('responsive', () => { s.unresponsive = false; });
}

/** Within `ms` after a start-up show: reload the page once if it is not loaded and drawn. Resolves to what it did. */
export function ensurePageShown(
  w: GuardWindow,
  why: string,
  ms = PAGE_GUARD_MS,
  wait: (ms: number) => Promise<void> = (n) => new Promise((r) => setTimeout(r, n)),
): Promise<'ok' | 'reloaded' | 'skipped'> {
  return wait(ms).then(async () => {
    if (w.isDestroyed()) return 'skipped';
    const s = states.get(w) ?? { loaded: false, gone: false, unresponsive: false };
    const crashed = w.webContents.isCrashed();
    let drawn = false;
    if (s.loaded && !s.gone && !crashed && !s.unresponsive) {
      drawn = await Promise.race([
        w.webContents.executeJavaScript(PAGE_DRAWN_JS).then((v) => v === true, () => false),
        wait(PAGE_PROBE_MS).then(() => false),
      ]);
    }
    const seen = { why, loaded: s.loaded, drawn, gone: s.gone, crashed, unresponsive: s.unresponsive };
    if (drawn) { log.info('start-up window shows its page', seen); return 'ok'; }
    if (reloadedOnce) { log.warn('start-up window still not drawn; already reloaded once', seen); return 'skipped'; }
    reloadedOnce = true;
    log.warn('start-up window not drawn: reloading its page once', seen);
    try { w.webContents.reload(); }
    catch (err) { log.warn('could not reload the start-up window', { err: (err as Error).message }); }
    return 'reloaded';
  });
}

/** Tests only. */
export function resetPageGuardForTests(): void { reloadedOnce = false; }
