// ─── Is DNS really left over after a session? (F15, UPSTREAM-GAPS #25) — macOS ───
// dvpnd's networksetup backend saves every network service's DNS servers, sets the VPN's on each
// (`networksetup -setdnsservers`), and puts the saved ones back on stop. Before alarming the user
// about dns_revert_failed, look: a real leftover is one of the VPN's DNS servers still set on a
// network service.
import { execFile } from 'node:child_process';
import { log } from '../logger';

export interface AdapterDns { alias: string; servers: string[] }

/** Pure decision, exported for tests. */
export function leftoverDns(adapters: AdapterDns[], vpnServers: string[]): AdapterDns[] {
  const ours = new Set(vpnServers.map((s) => s.trim().toLowerCase()).filter(Boolean));
  if (!ours.size) return [];
  return adapters.filter((a) => a.servers.some((s) => ours.has(s.toLowerCase())));
}

/**
 * Parse `networksetup -listallnetworkservices`:
 *   An asterisk (*) denotes that a network service is disabled.
 *   Ethernet
 *   *Thunderbolt Bridge
 * → enabled service names. Exported for tests.
 */
export function parseNetworkServices(out: string): string[] {
  return out.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('An asterisk') && !l.startsWith('*'));
}

/** Parse `networksetup -getdnsservers <svc>` ("There aren't any DNS Servers set on …" = none). Exported for tests. */
export function parseDnsServers(out: string): string[] {
  if (/There aren't any DNS Servers/i.test(out)) return [];
  return out.split(/\r?\n/).map((l) => l.trim()).filter((l) => /^[0-9a-f.:]+$/i.test(l));
}

const run = (args: string[]): Promise<string> => new Promise((resolve, reject) => {
  execFile('/usr/sbin/networksetup', args, { timeout: 15_000 }, (err, stdout) => (err ? reject(err) : resolve(String(stdout))));
});

async function adapterDns(): Promise<AdapterDns[]> {
  const services = parseNetworkServices(await run(['-listallnetworkservices']));
  const rows: AdapterDns[] = [];
  for (const svc of services) {
    try {
      const servers = parseDnsServers(await run(['-getdnsservers', svc]));
      if (servers.length) rows.push({ alias: svc, servers });
    } catch (err) {
      log.warn('networksetup -getdnsservers failed', { svc, err: (err as Error).message });
    }
  }
  return rows;
}

/**
 * true = the VPN's DNS is still set somewhere (tell the user), false = the daemon's
 * report was a false alarm. Unknown (no servers, check failed) = true.
 */
export async function dnsReallyLeftOver(vpnServers: string[] | undefined): Promise<boolean> {
  if (!vpnServers?.length) return true;
  try {
    const left = leftoverDns(await adapterDns(), vpnServers);
    if (left.length) log.warn('VPN DNS still set', { services: left.map((a) => a.alias) });
    else log.info('dns_revert_failed was a false alarm: no network service keeps the VPN DNS');
    return left.length > 0;
  } catch (err) {
    log.warn('DNS leftover check failed', { err: (err as Error).message });
    return true;
  }
}

/**
 * Drop the directory-service cache after a tunnel comes up or goes down: answers cached on the
 * old path are wrong for the new one. (dvpnd also signals mDNSResponder as root when it changes
 * DNS.) Fire and forget, logged.
 */
export function flushDnsCache(): void {
  execFile('/usr/bin/dscacheutil', ['-flushcache'], { timeout: 10_000 }, (err, stdout, stderr) => {
    if (err) log.warn('flushing the DNS cache failed', flushFailure(err, stdout, stderr));
  });
}

/** #31 1ec4cfc (row 134): a failed flush is logged with its exit code, signal, whether it timed out, and what the
 *  program printed (both streams, cut short), never "Command failed" alone. */
export function flushFailure(err: Error, stdout: unknown, stderr: unknown): Record<string, unknown> {
  const e = err as Error & { code?: number | string | null; signal?: string | null; killed?: boolean };
  const cut = (s: unknown): string => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 300);
  return { err: e.message.split('\n')[0], code: e.code ?? null, signal: e.signal ?? null, timedOut: e.killed === true, stdout: cut(stdout), stderr: cut(stderr) };
}

/** Shared name (#31 0e425d8): the flush was refused for lack of admin rights. dscacheutil needs none on macOS, so
 *  this only matches the Windows/other wording the shared test pins; a match here is still just logged. */
export const flushNeedsAdmin = (f: Record<string, unknown>): boolean => /requires elevation|access is denied/i.test(`${String(f.stdout)} ${String(f.stderr)} ${String(f.err)}`);
