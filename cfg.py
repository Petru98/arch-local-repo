#!/usr/bin/python
import asyncio
import json
import logging
import os
import subprocess
import sys
import tarfile

from tempfile import gettempdir


_log_handler = logging.StreamHandler()
_log_handler.setFormatter(logging.Formatter('{levelname}: {message}', style='{'))
log = logging.getLogger()
log.addHandler(_log_handler)
log.setLevel(logging.WARNING)

rootdir = os.path.abspath(os.path.dirname(sys.argv[0]))
env = os.environ
tmpdir = gettempdir()

CARCH_DEFAULT = os.uname().machine
SRCDEST_DEFAULT = env["HOME"]+'/.cache/aur'
PKGEXT_DEFAULT = '.pkg.tar.zst'
SRCEXT_DEFAULT = '.src.tar.gz'
SRCPKGDEST_DEFAULT = rootdir
BUILDDIR_DEFAULT = tmpdir+'/makepkg'


# Util
def die(*args, **kwargs):
    log.critical(*args, **kwargs)
    exit(1)

def statfile(path):
    try:                      r = os.stat(path)
    except FileNotFoundError: r = None
    return r

def modtimecmp(path1, path2):
    try:                      t1 = os.stat(path1).st_mtime_ns
    except FileNotFoundError: t1 = 0
    try:                      t2 = os.stat(path2).st_mtime_ns
    except FileNotFoundError: t2 = 0
    return t1 - t2

def run(args, **kwargs):
    kwargs.setdefault('text', True)
    kwargs.setdefault('check', True)
    proc = subprocess.run(args, **kwargs)

    if kwargs['check']:
        r = list(filter(lambda x: x is not None, (proc.stdout, proc.stderr)))
    else:
        r = (proc.returncode, *filter(lambda x: x is not None, (proc.stdout, proc.stderr)))

    return r if len(r) >= 2 else r[0] if len(r) == 1 else None


async def run_async(args, **kwargs):
    text = kwargs.pop('text', True)
    check = kwargs.pop('check', True)
    shell = kwargs.pop('shell', False)
    input = kwargs.pop('input', None)

    if shell:
        proc = await asyncio.create_subprocess_shell(args, **kwargs)
    else:
        proc = await asyncio.create_subprocess_exec(*args, **kwargs)

    if input is not None or asyncio.subprocess.PIPE in map(lambda k: kwargs.get(k), ('stdout', 'stderr')):
        stdout, stderr = await proc.communicate(input)
    else:
        await proc.wait()
        stdout, stderr = None, None

    if text:
        if stdout is not None: stdout = stdout.decode()
        if stderr is not None: stderr = stderr.decode()

    if check:
        if proc.returncode != 0:
            die(f'failed to run {args} ({proc.returncode}) with kwargs {kwargs}')
        r = list(filter(lambda x: x is not None, (stdout, stderr)))
    else:
        r = (proc.returncode, *filter(lambda x: x is not None, (stdout, stderr)))

    return r if len(r) >= 2 else r[0] if len(r) == 1 else None

async def waitall(aws):
    futures = [asyncio.create_task(x) if asyncio.iscoroutine(x) else x for x in aws]
    if futures:
        await asyncio.wait(futures)



# Utils for packages
class Srcinfo:
    checksum_algos = ('md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512', 'b2')


    _somemultiarch_arrays = (
        'source', 'conflicts', 'provides', 'replaces',
    )
    _anyarch_arrays = {
        'pkgname', 'arch', 'groups', 'license', 'noextract', 'options', 'backup', 'validpgpkeys',
        'depends', 'makedepends', 'checkdepends', 'optdepends',
        *_somemultiarch_arrays,
        *map(lambda x: x+'sums', checksum_algos),
    }
    @staticmethod
    def isarray(key):
        return (
            ('_' in key and ('sums' in key or 'depends' in key or any(key.startswith(x) for x in Srcinfo._somemultiarch_arrays))) or
            (key in Srcinfo._anyarch_arrays)
        )


    _multiarch_pkgspecific_keys = (
        'depends', 'optdepends',
        'conflicts', 'provides', 'replaces',
    )
    _anyarch_pkgspecific_keys = {
        'pkgdesc', 'url', 'install', 'changelog',
        'arch', 'groups', 'license', 'noextract', 'options', 'backup',
        *_multiarch_pkgspecific_keys,
    }
    @staticmethod
    def canbeoverriden(key):
        return (
            ('_' in key and any(key.startswith(x) for x in Srcinfo._multiarch_pkgspecific_keys)) or
            (key in Srcinfo._anyarch_pkgspecific_keys)
        )


    @staticmethod
    def archsuffixes(srcinfo):
        if srcinfo['arch'][0] == 'any':
            return ['']
        return ['', *map(lambda x: '_'+x, srcinfo['arch'])]

    @staticmethod
    def version(srcinfo):
        return f'{srcinfo["epoch"]+":" if "epoch" in srcinfo else ""}{srcinfo["pkgver"]}-{srcinfo["pkgrel"]}'

    @staticmethod
    def splitsource(source):
        filename, _, url = source.rpartition('::')

        i = url.find('://')
        if i >= 0:
            j = url.find('+', 0, i)
            if j >= 0:
                protocol = url[:j]
                url = url[j+1:]
            else:
                protocol = url[:i]
        else:
            protocol = 'local'

        if not filename:
            if protocol == 'local':
                filename = url.rstrip('/').rpartition('/')[2]
            else:
                filename = url.partition('#')[0].partition('?')[0].rstrip('/').rpartition('/')[2]
                if protocol == 'git':
                    filename = filename.removesuffix('.git')

        return filename, protocol, url


    @staticmethod
    def iteratelines(iterator, filename='<iterator>'):
        for i, line in enumerate(iterator, start=1):
            line = line.strip()
            if line and line[0] != '#':
                key, eq, value = line.partition('=')
                if not key or not eq:
                    raise RuntimeError(f'{filename}:{i}: invalid line "{line}"')
                yield i, key.rstrip(), value.lstrip()

    @staticmethod
    def iteratefile(path):
        with open(path) as fd:
            yield from Srcinfo.iteratelines(fd, path)

    @staticmethod
    def iteratestr(s):
        yield from Srcinfo.iteratelines(s.splitlines(), '<string>')


    @staticmethod
    def parse(linesiterator, filename='<iterator>'):
        srcinfo = {'packages': {}}
        info = srcinfo

        for i, key, value in linesiterator:
            if key == 'pkgbase':
                assert 'pkgbase' not in srcinfo
                assert info is srcinfo
                srcinfo['pkgbase'] = value

            elif key == 'pkgname':
                info = srcinfo['packages'][value] = {}

            elif Srcinfo.isarray(key):
                assert info is srcinfo or Srcinfo.canbeoverriden(key)
                info.setdefault(key, [])
                if value and value not in info[key]:
                    info[key].append(value)

            else:
                assert info is srcinfo or Srcinfo.canbeoverriden(key)
                assert key not in info
                info[key] = value

        assert 'arch' in srcinfo and len(srcinfo['arch']) >= 1
        assert len(srcinfo['arch']) == 1 or 'any' not in srcinfo['arch']

        # check that the lengths of source and checksum arrays match
        for suffix in Srcinfo.archsuffixes(srcinfo):
            sources = 'source' + suffix
            if sources in srcinfo:
                for algo in Srcinfo.checksum_algos:
                    checksums = algo + 'sums' + suffix
                    if checksums in srcinfo:
                        assert len(srcinfo[sources]) == len(srcinfo[checksums])

        # set default values to packages if necessary (srcinfo[package][key] is srcinfo[key])
        for key, value in srcinfo.items():
            if Srcinfo.canbeoverriden(key):
                for info in srcinfo['packages'].values():
                    if key not in info:
                        info[key] = value

        return srcinfo

    @staticmethod
    def parsefile(path):
        return Srcinfo.parse(Srcinfo.iteratefile(path), path)
    @staticmethod
    def parsestr(s):
        return Srcinfo.parse(Srcinfo.iteratestr(s), '<string>')


def isvcs(pkgname):
    return any(pkgname.endswith(suffix) for suffix in ('-git','-svn','-bzr','-hg','-cvs','-nightly'))

def issrcinfooutdated(pkgbase):
    path = f'{rootdir}/{pkgbase}'
    return modtimecmp(path + '/.SRCINFO', path + '/PKGBUILD') < 0

def iterdbpkgs(db):
    with tarfile.open(db, 'r|*') as tar:
        for tarinfo in tar:
            if tarinfo.isdir():
                i = tarinfo.name.rindex('-', 0, tarinfo.name.rindex('-'))
                yield tarinfo.name[:i], tarinfo.name[i+1:]



# Shared code
def iterpkgs(pkgs, devel=None):
    if not pkgs:
        with os.scandir(rootdir) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    if os.path.exists(f'{entry.path}/PKGBUILD'):
                        if devel or not isvcs(entry.name):  # None is treated as False in this case
                            yield entry.name
                        else:
                            log.warning(f'skipping {entry.name}: no-devel flag is set')
    else:
        for pkg in pkgs:
            if not os.path.exists(f'{rootdir}/{pkg}/PKGBUILD'):
                die(f'{pkg}/PKGBUILD does not exist')
            if devel is not False or not isvcs(pkg):  # None is treated as True in this case
                yield pkg
            else:
                log.warning(f'skipping {pkg}: no-devel flag is set')


async def generate_srcinfo_async(pkgbase):
    stdout = await run_async(['makepkg', '--printsrcinfo'],
        cwd=f'{rootdir}/{pkgbase}', stdout=asyncio.subprocess.PIPE
    )
    return stdout

async def update_srcinfo_async(pkgbase, contents=None):
    if contents is None:
        contents = await generate_srcinfo_async(pkgbase)
    with open(f'{rootdir}/{pkgbase}/.SRCINFO', 'w') as fd:
        fd.write(contents)
    return contents

async def read_srcinfo_async(pkgbase, /, cache):
    if issrcinfooutdated(pkgbase):
        if cache: return await update_srcinfo_async(pkgbase)
        else:     return await generate_srcinfo_async(pkgbase)  # noqa: E272
    with open(f'{rootdir}/{pkgbase}/.SRCINFO', 'r') as fd:
        return fd.read()



# makepkg.conf
def envconf_get(conf, key, default=None):
    if key in env: return env[key]
    if key in conf: return conf[key]
    return default

def envconf_setdefault(conf, key, default=None):
    if key in env: return env[key]
    if key in conf: return conf[key]
    if default is not None: env[key] = default
    return default

async def read_makepkgconf_async(path=None):
    if path is None:
        for x in (f'{rootdir}/makepkg.conf',
                  f'{env["HOME"]}/.config/pacman/makepkg.conf',
                  f'{env["HOME"]}/.makepkg.conf',
                  '/etc/makepkg.conf'
        ):
            if os.path.exists(x):
                path = x
                break
        assert path is not None

    stdout = await run_async(['env', '-i', f'{rootdir}/print-makepkgconf', path],
        stdout=asyncio.subprocess.PIPE
    )
    return json.loads(stdout)
