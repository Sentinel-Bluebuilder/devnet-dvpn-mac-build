// ─── cliErr: one coded failure for every CLI command (#38 R2) ───
// A bare `throw new Error(…)` reached an agent as `code: null, action: null`, exit 1 (ERROR-MAP: 24 sites on the
// agent path). Every failure now carries a code (exit + money class by code) and the one command to run next.
// No imports: keystore.ts and the command files all use it without a cycle.

/** How the agent runs this CLI (as agent-cmd.ts). */
export const CLI_NAME = process.env.DVPN_CLI_NAME || 'devnet-dvpn';

/** An Error that errorOutput prints as { ok:false, error: message, code, action: next, next }. */
export function cliErr(code: string, next: string | null, message: string): Error & { code: string; action: string | null } {
  return Object.assign(new Error(message), { code, action: next });
}

/** R2: the next step after device setup: the service when it is not running, else the connect. Pure; unit-tested. */
export function deviceNext(service: string | undefined | null): string {
  return service === 'no-service' || service === 'no-right' || service === 'failed'
    ? `${CLI_NAME} daemon install --yes`
    : `${CLI_NAME} agent up --yes`;
}

/** P-N (#38 rc.8, Windows R4): `device setup` before the service holds a device key. ONE command: `agent up --yes`
 *  creates the key and sets the device up itself when the service is installed; without the service, install it.
 *  Pure; unit-tested. */
export function noDeviceKeyNext(serviceReachable: boolean): string {
  return serviceReachable ? `${CLI_NAME} agent up --yes` : `${CLI_NAME} daemon install --yes`;
}

/** R2 (S5): the public row that explains a code (docs/CODES.md, one anchor per code, checked by check-glossary). */
export const CODES_URL = 'https://github.com/Sentinel-Bluebuilder/agentic-privacy-solana-devnet/blob/main/docs/CODES.md';
export function docUrlFor(code: string): string {
  return `${CODES_URL}#code-${code.toLowerCase().replace(/[^a-z0-9_-]+/g, '-')}`;
}
