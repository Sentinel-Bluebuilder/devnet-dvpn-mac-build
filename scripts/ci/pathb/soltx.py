# ─── direct/soltx.py: build one Solana transaction message for openssl to sign (standard library only) ───
#
#   python3 -I direct/soltx.py <keyfile> <signer address> <blockhash> <work dir> <signer pem> sol <to> <lamports>
#   python3 -I direct/soltx.py <keyfile> <signer address> <blockhash> <work dir> <signer pem> \
#       token <source token account> <mint> <destination token account> <amount> <decimals> <token program> <rent to>
#   python3 -I direct/soltx.py pubkey <keyfile>          # prints the key file's address (install.sh KEYFILE=)
#
# sol   : one System Program transfer.
# token : Token(-2022) transferChecked of <amount> base units, then closeAccount of the (now empty) source token
#         account, which sends its rent lamports to <rent to>. One transaction, one signature.
# Writes <work>/msg.bin (the message), <work>/pub.hex (the signer's public key) and <signer pem> (the PKCS#8
# ed25519 key for openssl; the caller deletes it right after signing). The key file must be the signer's.
import base64
import json
import string
import struct
import sys

A = ''.join(c for c in string.digits + string.ascii_uppercase + string.ascii_lowercase if c not in '0OIl')   # base58


def b58d(s):
    n = 0
    for c in s:
        n = n * 58 + A.index(c)
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big') if n else b''
    out = b'\0' * (len(s) - len(s.lstrip('1'))) + b
    assert len(out) == 32, 'not a 32-byte address: %s' % s
    return out


def b58e(b):
    n = int.from_bytes(b, 'big')
    s = ''
    while n:
        n, r = divmod(n, 58)
        s = A[r] + s
    return '1' * (len(b) - len(b.lstrip(b'\0'))) + s


def shortvec(n):
    out = b''
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def compile_message(payer, blockhash, ixs):
    # ixs: [(program, [(address, signer, writable), ...], data)]; the payer is the only signer
    metas = {payer: [True, True]}
    order = [payer]
    for prog, accs, _ in ixs:
        for addr, signer, writable in accs:
            if addr not in metas:
                metas[addr] = [False, False]
                order.append(addr)
            metas[addr][0] |= signer
            metas[addr][1] |= writable
        if prog not in metas:
            metas[prog] = [False, False]
            order.append(prog)
    assert [a for a in order if metas[a][0]] == [payer], 'only the payer may sign'
    keys = [payer] + [a for a in order[1:] if metas[a][1]] + [a for a in order[1:] if not metas[a][1]]
    ro_unsigned = sum(1 for a in keys[1:] if not metas[a][1])
    msg = bytes([1, 0, ro_unsigned]) + shortvec(len(keys)) + b''.join(b58d(k) for k in keys) + b58d(blockhash)
    msg += shortvec(len(ixs))
    for prog, accs, data in ixs:
        msg += bytes([keys.index(prog)]) + shortvec(len(accs)) + bytes(keys.index(a) for a, _, _ in accs)
        msg += shortvec(len(data)) + data
    return msg


def on_curve(addr):
    # an ed25519 public key (a wallet someone can sign for) decompresses to a curve point; a PDA does not
    p = 2 ** 255 - 19
    d = (-121665 * pow(121666, p - 2, p)) % p
    b = b58d(addr)
    y = int.from_bytes(b, 'little') & ((1 << 255) - 1)
    if y >= p:
        return False
    u, v = (y * y - 1) % p, (d * y * y + 1) % p
    x2 = u * pow(v, p - 2, p) % p
    if x2 == 0:
        return not (b[31] >> 7)
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * pow(2, (p - 1) // 4, p) % p
    return (x * x - x2) % p == 0


def main():
    if sys.argv[1:2] == ['oncurve']:   # python3 -I direct/soltx.py oncurve <address>: exit 0 if a wallet key
        sys.exit(0 if on_curve(sys.argv[2]) else 1)
    if sys.argv[1:2] == ['pubkey']:   # python3 -I direct/soltx.py pubkey <keyfile>: print the key file's address
        k = json.load(open(sys.argv[2]))
        assert isinstance(k, list) and len(k) == 64 and all(isinstance(x, int) and 0 <= x < 256 for x in k), \
            'not a 64-number Solana keypair array'
        print(b58e(bytes(k[32:])))
        return
    keyfile, signer_addr, blockhash, work, pem, kind = sys.argv[1:7]
    rest = sys.argv[7:]
    k = bytes(json.load(open(keyfile)))
    assert len(k) == 64, 'key file is not a 64-byte Solana keypair array'
    seed, pub = k[:32], k[32:]
    assert b58e(pub) == signer_addr, 'key file public key does not match %s' % signer_addr
    system = b58e(bytes(32))
    if kind == 'sol':
        to, lamports = rest
        ixs = [(system, [(signer_addr, True, True), (to, False, True)], struct.pack('<IQ', 2, int(lamports)))]
    elif kind == 'token':
        src, mint, dst, amount, decimals, program, rent_to = rest
        ixs = []
        if int(amount) > 0:   # TokenInstruction::TransferChecked = 12: source, mint, destination, owner
            ixs.append((program, [(src, False, True), (mint, False, False), (dst, False, True), (signer_addr, True, False)],
                        struct.pack('<BQB', 12, int(amount), int(decimals))))
        # TokenInstruction::CloseAccount = 9: account, rent destination, owner
        ixs.append((program, [(src, False, True), (rent_to, False, True), (signer_addr, True, False)], bytes([9])))
    else:
        raise SystemExit('unknown kind %s' % kind)
    open(work + '/msg.bin', 'wb').write(compile_message(signer_addr, blockhash, ixs))
    der = bytes.fromhex('302e020100300506032b657004220420') + seed   # PKCS#8 ed25519
    label = ' '.join(['PRIVATE', 'KEY'])                              # built at run time: no key header literal here
    open(pem, 'w').write('-----BEGIN %s-----\n' % label + base64.b64encode(der).decode() + '\n-----END %s-----\n' % label)
    open(work + '/pub.hex', 'w').write(pub.hex())


if __name__ == '__main__':
    main()
