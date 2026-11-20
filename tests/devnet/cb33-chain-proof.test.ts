// ─── On-chain proof of the cb33 chain port (rent-recipient args, rent_recipient fields) ───
// TEST_KEYFILE=<wallet> P0_NODE=<node> npx vitest run tests/devnet/cb33-chain-proof.test.ts
// Two txs, 7 s apart: an owner-signed voucher open_channel, then start_close_channel. The channel
// is left closing; its rent and escrow come back on close_channel after the grace.
import { describe, it, expect } from 'vitest';
import { randomBytes } from 'node:crypto';
import { PublicKey } from '@solana/web3.js';
import { setRpcUrls } from '../../src/core/chain/rpc';
import { pda } from '../../src/core/chain/program';
import * as b from '../../src/core/chain/builders';
import { channelByPda, nodeByPda, userByOwner } from '../../src/core/chain/accounts';
import { CHANNEL_STATUS_CLOSING, CHANNEL_STATUS_OPEN } from '../../src/core/chain/idl';
import { testKeypair, land } from './_signer';

if (process.env.SOLANA_RPC_URLS) setRpcUrls(process.env.SOLANA_RPC_URLS.split(','));
const kp = testKeypair();
const NODE = process.env.P0_NODE ?? '';

describe.skipIf(!kp || !NODE).sequential('cb33 chain port on devnet', () => {
  const owner = kp ? kp.publicKey : PublicKey.default;
  it('open_channel (voucher) lands and stores the owner as rent recipient; start_close_channel lands', async () => {
    const node = await nodeByPda(NODE);
    expect(node, `no node account ${NODE}`).not.toBeNull();
    const id = randomBytes(32);
    const ch = pda.channel(owner, id).toBase58();
    await land(kp!, [await b.openChannel({ owner, node: node!, channelId: id, escrow: '10000', mode: 0 })], 'open_channel:voucher:cb33');
    const opened = await channelByPda(ch);
    console.log(`[channel] ${ch}`);
    expect(opened.status).toBe(CHANNEL_STATUS_OPEN);
    expect(String(opened.escrow)).toBe('10000');
    expect(String(opened.rentRecipient)).toBe(owner.toBase58());
    expect(String((await userByOwner(owner.toBase58())).rentRecipient)).toBe(owner.toBase58());
    await land(kp!, [await b.startCloseChannel({ owner, channel: ch })], 'start_close_channel:cb33');
    expect((await channelByPda(ch)).status).toBe(CHANNEL_STATUS_CLOSING);
  }, 120_000);
});
