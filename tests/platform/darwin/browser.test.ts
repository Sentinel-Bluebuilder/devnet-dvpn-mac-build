import { describe, it, expect } from 'vitest';
import { browserArgs, browserCandidates, findBrowser } from '../../../src/main/system/browser';
import { parseArgs, str } from '../../../src/cli/args';

const fwd = (p: string): string => p.split('\\').join('/');

describe('browser through the VPN (F16.2) — macOS', () => {
  it('sends everything to the SOCKS endpoint and keeps DNS off this computer', () => {
    const a = browserArgs('127.0.0.1:1080', '/Users/u/p', 'https://api.ipify.org');
    expect(a).toContain('--proxy-server=socks5://127.0.0.1:1080');
    expect(a).toContain('--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1');
    expect(a).toContain('--user-data-dir=/Users/u/p');
    expect(a).toContain('--disable-quic');
    expect(a[a.length - 1]).toBe('https://api.ipify.org/');
  });
  it('W31-16: --url is a web address, never a browser flag (a flag would send the window direct)', () => {
    for (const bad of ['--proxy-server=direct://', ' --proxy-server=direct://', '-incognito', 'file:///etc/passwd', 'javascript:alert(1)', 'chrome://settings', 'not a url']) {
      expect(() => browserArgs('127.0.0.1:1080', 'p', bad), bad).toThrow(/not an http\(s\) web address/);
    }
    // AC-WIN's live form on Windows: the ONE-word `--url=--proxy-server=direct://`, exactly as the CLI parser hands it on
    const cli = str(parseArgs(['proxy', 'browser', '--url=--proxy-server=direct://']), 'url');
    expect(cli).toBe('--proxy-server=direct://');
    expect(() => browserArgs('127.0.0.1:1080', 'p', cli as string)).toThrow(/not an http\(s\) web address/);
    const a = browserArgs('127.0.0.1:1080', 'p', 'https://example.com/a b');
    expect(a.filter((x) => x.startsWith('--proxy-server='))).toEqual(['--proxy-server=socks5://127.0.0.1:1080']);
    expect(a[a.length - 1]).toBe('https://example.com/a%20b');
  });
  it('refuses anything but a local SOCKS endpoint', () => {
    expect(() => browserArgs('10.0.0.1:1080', 'p', 'u')).toThrow(/not a local SOCKS endpoint/);
    expect(() => browserArgs('127.0.0.1:1080 --evil', 'p', 'u')).toThrow();
  });
  it('looks in /Applications, then ~/Applications, inside the app bundle', () => {
    expect(browserCandidates('chrome', '/Users/u').map(fwd)).toEqual([
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Users/u/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    ]);
    expect(fwd(browserCandidates('brave', '/Users/u')[0])).toBe('/Applications/Brave Browser.app/Contents/MacOS/Brave Browser');
    expect(findBrowser('edge', () => false)).toBeNull();
  });
});
