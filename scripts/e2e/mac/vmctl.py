#!/usr/bin/env python3
# ─── Drive the macOS guest through QMP (on ddv-mac-host-1) ───
# shot OUT.png            screenshot (PNG via ImageMagick)
# click X Y [right|dbl]   click at screen pixel X,Y (usb-tablet absolute coords)
# key COMBO...            e.g. key ret | key meta_l-space | key tab tab ret
# type TEXT               type ASCII text (US layout)
# type-stdin             type one line read from stdin (passwords: never on argv)
# hmp COMMAND             raw monitor command
import json, os, socket, subprocess, sys, time

SOCK = os.path.expanduser('~/qmp.sock')
W, H = int(os.environ.get('VM_W', 1280)), int(os.environ.get('VM_H', 800))

def qmp(*cmds):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK); f = s.makefile('rw')
    f.readline(); f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n'); f.flush(); f.readline()
    out = []
    for c in cmds:
        f.write(json.dumps(c) + '\n'); f.flush()
        while True:
            r = json.loads(f.readline())
            if 'event' in r: continue
            out.append(r); break
    s.close(); return out

def ev(evts): return {'execute': 'input-send-event', 'arguments': {'events': evts}}
def btn(b, down): return {'type': 'btn', 'data': {'down': down, 'button': b}}
def absmove(x, y): return [{'type': 'abs', 'data': {'axis': 'x', 'value': int(x * 32767 / (W - 1))}},
                           {'type': 'abs', 'data': {'axis': 'y', 'value': int(y * 32767 / (H - 1))}}]

SHIFT = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
         '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash', ':': 'semicolon',
         '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', chr(92): 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent', '\n': 'ret'}

def sendkey(combo):
    keys = [{'type': 'qcode', 'data': k} for k in combo.split('-')]
    qmp({'execute': 'send-key', 'arguments': {'keys': keys, 'hold-time': 60}}); time.sleep(0.08)

def main(a):
    cmd = a[0]
    if cmd == 'shot':
        tmp = '/tmp/vmctl.ppm'
        qmp({'execute': 'screendump', 'arguments': {'filename': tmp}})
        time.sleep(0.3)
        subprocess.run(['convert', tmp, a[1]], check=True); print(a[1])
    elif cmd == 'click':
        x, y = float(a[1]), float(a[2]); kind = a[3] if len(a) > 3 else 'left'
        b = 'right' if kind == 'right' else 'left'
        qmp(ev(absmove(x, y))); time.sleep(0.15)
        for _ in range(2 if kind == 'dbl' else 1):
            qmp(ev([btn(b, True)])); time.sleep(0.06); qmp(ev([btn(b, False)])); time.sleep(0.08)
    elif cmd == 'move':
        qmp(ev(absmove(float(a[1]), float(a[2]))))
    elif cmd == 'key':
        for c in a[1:]: sendkey(c)
    elif cmd in ('type', 'type-stdin'):
        # type-stdin: the text (a password) comes from stdin, never argv (ps, shell history)
        text = sys.stdin.readline().rstrip('\n') if cmd == 'type-stdin' else ' '.join(a[1:])
        for ch in text:
            if ch.isalpha() and ch.isupper(): sendkey('shift-' + ch.lower())
            elif ch.isalnum(): sendkey(ch)
            elif ch in SHIFT: sendkey('shift-' + SHIFT[ch])
            elif ch in PLAIN: sendkey(PLAIN[ch])
            else: raise SystemExit(f'cannot type {ch!r}')
    elif cmd == 'hmp':
        print(qmp({'execute': 'human-monitor-command', 'arguments': {'command-line': ' '.join(a[1:])}})[0].get('return', ''))
    else:
        raise SystemExit(__doc__)

main(sys.argv[1:])
