// Desktop words for an empty settings copy (Q0544), macOS twin of #31 7103715: Install service (or
// `devnet-dvpn daemon install`) rewrites the copy; a missing copy says install first.
import { describe, expect, it } from 'vitest';
import { EMPTY_SETTINGS_COPY, unreadableSettingsCopy } from '../../../src/shared/settings-copy';

describe('desktop settings-copy words', () => {
  it('an empty copy names Install service; a missing one says install first', () => {
    expect(EMPTY_SETTINGS_COPY).toMatch(/is empty.*Install service/);
    expect(unreadableSettingsCopy(false)).toMatch(/Install the service first/);
  });
});
