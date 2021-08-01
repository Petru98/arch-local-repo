#!/usr/bin/python3
import io
import os
import os.path
import platform
import re
import shlex
import subprocess
import sys
import types

from pathlib import Path
from subprocess import DEVNULL, PIPE


SCRIPTDIR = Path(sys.argv[0]).parent


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

class TeeFd(io.IOBase):
    def __init__(self, *files):
        self.files = files
    def read(self, *args):
        raise io.UnsupportedOperation('read')
    def write(self, x):
        for file in self.files:
            file.write(x)
            file.flush()
    def flush(self):
        for file in self.files:
            file.flush()

logfilepath = f'{SCRIPTDIR}/{Path(sys.argv[0]).stem}.log'
logfilefd = open(logfilepath, 'w', closefd=True)
ologfd = TeeFd(sys.stdout, logfilefd)
elogfd = TeeFd(sys.stderr, logfilefd)
loglinesep = '#' * os.get_terminal_size()[0]

def esc(*args):
    return f'\033[{";".join(map(str, args))}m'

def olog(m):
    ologfd.write(m + '\n')
def elog(m):
    elogfd.write(m + '\n')

def info(m):
    elogfd.write(f'{esc(Bold)}[+] INFO: {m}{esc(Reset)}\n')
def warning(m):
    elogfd.write(f'{esc(Bold,FYellow)}[!] WARNING: {m}{esc(Reset)}\n')
def error(m):
    elogfd.write(f'{esc(Bold,FRed)}[-] ERROR: {m}{esc(Reset)}\n')
def critical(m):
    elogfd.write(f'{esc(Bold,BRed,FWhite)}[X] CRITICAL: {m}{esc(Reset)}\n')
    sys.exit(1)

def title(m):
    elogfd.write(f'\n{esc(Bold)}{loglinesep}\n# {m}\n{loglinesep}{esc(Reset)}\n')

def writeto(filename, contents, mode='w'):
    with open(filename, mode) as fd:
        return fd.write(contents)
def readfrom(filename, mode='r'):
    with open(filename, mode) as fd:
        return fd.read()


def pause():
    ologfd.write('Press Enter to continue...')
    input()

def prompt(msg=None, default=None):
    if msg is not None:
        ologfd.write(f'{msg}: ')
    x = input()
    if x == '':
        x = default
    return x

def prompt_bool(msg, default=None):
    while True:
        x = prompt(msg)
        if x is None:
            return default
        x = x.lower()
        if x.startswith('y'):
            return True
        if x.startswith('n'):
            return False
        error('invalid answer')

def prompt_choice(choices, prompt=None):
    if isinstance(choices, types.GeneratorType):
        choices = list(choices)

    while True:
        if prompt:
            ologfd.write(f'{prompt}:\n')
        for i, m in enumerate(choices):
            ologfd.write(f'{i}) {m}\n')

        try:
            i = int(input())
            if i in range(len(choices)):
                return i
        except ValueError:
            pass
        error('Invalid option. Try again.')



def get_run_args_list(args):
    if isinstance(args, str):
        args = shlex.split(args)
    elif len(args) == 1:
        if isinstance(args[0], (tuple, list)):
            args = args[0]
        elif isinstance(args[0], types.GeneratorType):
            args = tuple(args[0])
    return args

def get_run_args_str(args):
    if not isinstance(args, str):
        args = get_run_args_list(args)
        if len(args) == 1 and isinstance(args[0], str):
            args = args[0]
        else:
            args = shlex.join(args)
    return args

def process_run_args(args, kwargs):
    kwargs.setdefault('check', True)
    kwargs.setdefault('text', True)

    if kwargs.setdefault('shell', False):
        kwargs['shell'] = False
        executable = kwargs.setdefault('executable', None)
        kwargs['executable'] = None
        if executable:
            if isinstance(executable, str):
                executable = [executable]
        else:
            executable = []
        args = [*executable, '/bin/bash', '-c', 'set -e\n' + get_run_args_str(args[0]), *args[1:]]

    else:
        args = get_run_args_list(args)

    return args, kwargs


def run(*args, **kwargs):
    args, kwargs = process_run_args(args, kwargs)
    return subprocess.run(args, **kwargs)

def run_out(*args, **kwargs):
    kwargs.setdefault('stdout', PIPE)
    return run(*args, **kwargs).stdout.strip()

def run_log(*args, **kwargs):
    args, kwargs = process_run_args(args, kwargs)
    check = kwargs.pop('check')

    kwargs.setdefault('stdin', None)
    kwargs.setdefault('stdout', PIPE)
    kwargs.setdefault('stderr', PIPE)

    if 'input' not in kwargs:
        input = None
    else:
        input = kwargs.pop('input')
        if input is not None:
            assert kwargs['stdin'] is None
            kwargs['stdin'] = PIPE

    p = subprocess.Popen(args, **kwargs)
    goal = 0
    for i, f in enumerate((p.stdin, p.stdout, p.stderr)):
        if f is not None:
            goal |= 1 << i
            os.set_blocking(f.fileno(), False)

    done = 0
    while (done & goal) != goal:
        if p.stderr is not None:
            try:
                line = os.read(p.stderr.fileno(), 4096).decode()
                if not line: raise EOFError()
                elogfd.write(line)
            except BlockingIOError:
                pass
            except EOFError:
                p.stderr.close()
                p.stderr = None
                done |= (1 << 2)

        if p.stdout is not None:
            try:
                line = os.read(p.stdout.fileno(), 4096).decode()
                if not line: raise EOFError()
                ologfd.write(line)
            except BlockingIOError:
                pass
            except EOFError:
                p.stdout.close()
                p.stdout = None
                done |= (1 << 1)

        if input is not None:
            if len(input) == 0:
                input = None
                p.stdin.close()
                p.stdin = None
                done |= (1 << 0)
            else:
                n = p.stdin.write(input)
                input = input[:n]

    p.wait()
    if check and p.returncode != 0:
        raise subprocess.CalledProcessError(p.returncode, p.args)
    return subprocess.CompletedProcess(p.args, p.returncode)

def run_editor(*args):
    args = get_run_args_list(args)
    return run([os.environ['EDITOR'], *args])


def get_dev_path(dev):
    if dev[0] != '/':
        dev = ('/dev/mapper/' if dev in get_dev_path.lvm_list else '/dev/') + dev
    return dev
get_dev_path.lvm_list = run_out('lsblk | grep \'lvm\' | awk \'{print substr($1,3)}\'', shell=True).split()

def get_part_disk(part):
    return part[:next(i for i in range(len(part)) if part[i].isdigit())]



# These are set during runtime
title('https://wiki.archlinux.org/index.php/Unified_Extensible_Firmware_Interface')
with open('/sys/class/dmi/id/sys_vendor', 'r') as fd:
    if re.match(r'Apple .*Inc.', fd.read()):
        run(['modprobe', '-r', '-q', 'efivars'], check=False)
    else:
        run(['modprobe', '-q', 'efivars'], check=False)

if os.path.isdir('/sys/firmware/efi/'):
    if not os.path.ismount('/sys/firmware/efi/efivars'):
        run(['mount', '-t', 'efivarfs', 'efivarfs', '/sys/firmware/efi/efivars'])
    UEFI = True
    info('UEFI Mode detected.')
else:
    UEFI = False
    info('BIOS Mode detected.')

# Modify the scripts before using with another architecture (e.g. don't install the lib32-* packages, remove multilib repo from pacman.conf)
ARCHI = platform.machine()
assert ARCHI == 'x86_64'

WIRED_DEV = run_out('ip link | grep "ens\\|eno\\|enp" | awk \'{print $2}\'| sed \'s/://\' | sed \'1!d\'', shell=True)
WIRELESS_DEV = run_out('ip link | grep wlp | awk \'{print $2}\'| sed \'s/://\' | sed \'1!d\'', shell=True)


# Change these
os.environ['EDITOR'] = 'nano'

LINUX_VERSION = 'linux'
assert LINUX_VERSION in ('linux', 'linux-lts', 'linux-hardened', 'linux-zen')

BOOTLOADER = 'grub'
assert BOOTLOADER in (None, '', 'grub',)  # 'syslinux') + (('systemd', 'refind') if UEFI else ())



if os.geteuid() != 0:
    critical('You must run as root.')

run_log(f'for x in $(ls -1 "{SCRIPTDIR}/root/etc/sudoers.d") ; do visudo -cq -f "{SCRIPTDIR}/root/etc/sudoers.d/$x" ; done', shell=True)

title('Network Setup - https://wiki.archlinux.org/index.php/Network_configuration')
while run('ping -q -w5 -c1 $(ip route | grep default | awk \'NR==1 {print $3}\')', shell=True, check=False, stdout=DEVNULL, stderr=DEVNULL).returncode != 0:
    warning('Internet connection not found.')
    choice = prompt_choice(('Wired Automatic', 'Wired Manual', 'Wireless', 'Try again', 'Skip'), 'Select network configuration type')
    if choice == 0:
        info(f'Starting dhcpcd@{WIRED_DEV}.service')
        run_log(['systemctl', 'start', f'dhcpcd@{WIRED_DEV}.service'])

    elif choice == 1:
        info(f'Stopping dhcpcd@{WIRED_DEV}.service')
        run_log(['systemctl', 'stop', f'dhcpcd@{WIRED_DEV}.service'])
        ipaddr = prompt('IP Address')
        submask = prompt('Submask')
        gateway = prompt('Gateway')
        run_log(['ip', 'link', 'set', WIRED_DEV, 'up'])
        run_log(['ip', 'addr', 'add', f'{ipaddr}/{submask}', 'dev', WIRED_DEV])
        run_log(['ip', 'route', 'add', 'default', 'via', gateway])
        run_editor('/etc/resolv.conf')

    elif choice == 2:
        run(['iwctl'])

    elif choice == 3:
        continue

    elif choice == 4:
        break
