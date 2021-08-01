#!/usr/bin/xonsh
import os
import re
import sys
import xonsh.tools

from collections.abc import Iterable


Reset = 0
Reverse = 7
Bold = 1
SUnderline = 4
RUnderline = 24
FBlack  = 30
FRed    = 31
FGreen  = 32
FYellow = 33
FBlue   = 34
FPurple = 35
FCyan   = 36
FWhite  = 37
BBlack  = 40
BRed    = 41
BGreen  = 42
BYellow = 43
BBlue   = 44
BPurple = 45
BCyan   = 46
BWhite  = 47


def esc(*args):
    return f'\033[{";".join(map(str, args))}m'

def olog(*args, **kwargs):
    assert 'file' not in kwargs
    kwargs['file'] = sys.stdout
    print(*args, **kwargs)
def elog(*args, **kwargs):
    assert 'file' not in kwargs
    kwargs['file'] = sys.stderr
    print(*args, **kwargs)

def info(m):
    elog(f'{esc(Bold)}[+] INFO: {m}{esc(Reset)}')
def warning(m):
    elog(f'{esc(Bold,FYellow)}[!] WARNING: {m}{esc(Reset)}')
def error(m):
    elog(f'{esc(Bold,FRed)}[-] ERROR: {m}{esc(Reset)}')
def critical(m):
    elog(f'{esc(Bold,FWhite,BRed)}[X] CRITICAL: {m}{esc(Reset)}')
    sys.exit(1)
def title(m):
    loglinesep = '#' * os.get_terminal_size()[0]
    elog(f'\n{esc(Bold)}{loglinesep}\n# {m}\n{loglinesep}{esc(Reset)}')

def check(p, m=None):
    if not p:
        if m is not None:
            error(m)
        raise xonsh.tools.XonshCalledProcessError(p.returncode, p.executed_cmd, p.stdout, p.stderr, p)

def setkeyvalue(args):
    assert len(args) == 3
    file, key, val = args
    if ![grep -q @(fr'^{key}\( \|=\)') @(file)]:
        assert ![sed -E -i @(fr's/^#?\s*({key}\s*=\s*).*/\1{val}/') @(file)]
    else:
        assert ![printf '%s' @(f'{key}={val}') >> @(file)]



$EDITOR = 'nano'

keymap = 'us'
assert '' != $(find /usr/share/kbd/keymaps/ -name f'{keymap}.map.gz' -print -quit).strip()

locales = ('en_US', 'ro_RO', 'ja_JP')
assert all(x in $(cat /etc/locale.gen | grep UTF-8 | sed r'/@/d' | awk r'{print $1}' | sed r's/\..*$//' | sed r's/#//g' | uniq) for x in locales)

timezone = 'Europe/Bucharest'
assert timezone in $(timedatectl list-timezones)

rootmnt = p'/mnt'
efimnt = p'/boot/efi'
assert rootmnt.is_mount()
assert efimnt.is_mount()

initsys = 's6'
assert initsys in ('s6',)



def filterargs(args):
    return list(filter(None, args)) if isinstance(args, Iterable) and not isinstance(args, str) else args

def enablesv(args):
    args = filterargs(args)
    if initsys == 's6':
        $[s6-rc-bundle-update -c /etc/s6/rc/compiled add default @(args)]

def disablesv(args):
    args = filterargs(args)
    if initsys == 's6':
        $[s6-rc-bundle-update -c /etc/s6/rc/compiled delete default @(args)]



if os.geteuid() != 0:
    critical('You must run as root.')
assert ![ping artixlinux.org a> /dev/null]


if re.match(r'Apple .*Inc.', $(cat '/sys/class/dmi/id/sys_vendor')):
    $[modprobe -r -q efivars]
else:
    $[modprobe -q efivars]

if p'/sys/firmware/efi/'.is_dir():
    if not p'/sys/firmware/efi/efivars'.is_mount():
        assert ![mount -t efivarfs efivarfs /sys/firmware/efi/efivars]
    uefi = True
    info('UEFI mode detected.')
else:
    uefi = False
    info('BIOS mode detected.')
