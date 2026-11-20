// ─── Open a terminal with the CLI ready — Windows/macOS/Android stub (platform row, decision (a)) ───
// Shared cli-exec.ts calls openTerminal only on Linux; Windows (PowerShell) and macOS (Terminal) launch in cli-exec.
// Linux's own file (#32) has the terminal list and the spawn.
export function openTerminal(_rcFile: string): { ok: boolean; error?: string } {
  return { ok: false, error: 'Run devnet-dvpn from your own terminal.' };
}
