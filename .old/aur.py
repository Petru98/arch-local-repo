#!/usr/bin/python
# Dependencies: pyalpm

import argparse
import asyncio
import itertools
import logging
import os
import re
import stat
import subprocess
import sys
import tarfile

from tempfile import gettempdir
from pyalpm import vercmp
from pycman.config import PacmanConfig


logger = logging.getLogger()
rootdir = os.path.abspath(os.path.dirname(sys.argv[0]))

env = os.environ
env.setdefault('CARCH', os.uname().machine)
env.setdefault('SRCDEST', f'{env["HOME"]}/.cache/aur')
env.setdefault('PKGEXT', '.pkg.tar.zst')
env.setdefault('SRCEXT', '.src.tar.gz')



# Util
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
    kwargs.setdefault('check', False)
    kwargs.setdefault('text', True)
    proc = subprocess.run(args, **kwargs)
    return proc.returncode, proc.stdout, proc.stderr


async def run_async(args, **kwargs):
    text = kwargs.pop('text', True)
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
        if stdout: stdout = stdout.decode()
        if stderr: stderr = stderr.decode()
    return proc.returncode, stdout, stderr

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
        *_somemultiarch_arrays,
        'depends', 'makedepends', 'checkdepends', 'optdepends',
        'md5sums', 'sha1sums', 'sha224sums', 'sha256sums', 'sha384sums', 'sha512sums', 'b2sums',
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
        return itertools.chain([''], map(lambda x: '_'+x, srcinfo['arch']) if srcinfo['arch'][0] != 'any' else [])

    @staticmethod
    def version(srcinfo):
        return f'{srcinfo["epoch"]+":" if "epoch" in srcinfo else ""}{srcinfo["pkgver"]}-{srcinfo["pkgrel"]}'

    @staticmethod
    def archives(srcinfo):
        pkgdest = env.get('PKGDEST', '.')
        ext = env.get('PKGEXT', '.pkg.tar.zst')
        version = Srcinfo.version(srcinfo)
        for pkgname, pkginfo in srcinfo['packages'].items():
            arch = 'any' if 'any' in pkginfo.get('arch', srcinfo.get('arch')) else env['CARCH']
            yield pkgname, f'{pkgdest}/{pkgname}-{version}-{arch}{ext}'

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
    def arrayinsert(info, key, value):
        info.setdefault(key, [])
        if value and value not in info[key]:
            info[key].append(value)


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
                if 'pkgbase' in srcinfo:
                    raise RuntimeError(f'{filename}:{i}: pkgbase declared more than once')
                if info is not srcinfo:
                    raise RuntimeError(f'{filename}:{i}: pkgbase declared after pkgname')
                srcinfo['pkgbase'] = value

            elif key == 'pkgname':
                info = srcinfo['packages'][value] = {}

            elif Srcinfo.isarray(key):
                if info is not srcinfo and not Srcinfo.canbeoverriden(key):
                    raise RuntimeError(f'{filename}:{i}: {key} can only be in pkgbase')
                Srcinfo.arrayinsert(info, key, value)

            else:
                if info is not srcinfo and not Srcinfo.canbeoverriden(key):
                    raise RuntimeError(f'{filename}:{i}: {key} can only be in pkgbase')
                if key in info:
                    raise RuntimeError(f'{filename}:{i}: {key} declared more than once')
                info[key] = value

        if 'arch' not in srcinfo:
            raise RuntimeError(f'{filename}:{i}: arch not specified')
        if len(srcinfo['arch']) >= 2 and 'any' in srcinfo['arch']:
            raise RuntimeError(f'{filename}:{i}: package cannot be arch-specific and arch-independent simultaneously')

        # check that the lengths of source and checksum arrays match
        for suffix in Srcinfo.archsuffixes(srcinfo):
            sources = 'source' + suffix
            if sources in srcinfo:
                for algo in Srcinfo.checksum_algos:
                    checksums = algo + 'sums' + suffix
                    if checksums in srcinfo:
                        if len(srcinfo[sources]) != len(srcinfo[checksums]):
                            raise RuntimeError(f'{filename}:{i}: {sources} and {checksums} have different lengths')

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

def getdbpkgs(db):
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
                    statres = statfile(f'{entry.path}/PKGBUILD')
                    if statres:
                        if not stat.S_ISREG(statres.st_mode):
                            logger.error(f'skipping {entry.name}: PKGBUILD is not a regular file')
                        elif not devel and isvcs(entry.name):  # None is treated as False in this case
                            logger.warning(f'skipping {entry.name}: no-devel flag is set')
                        else:
                            yield entry.name
    else:
        for pkg in pkgs:
            if not os.path.isdir(f'{rootdir}/{pkg}'):
                raise RuntimeError(f'package {pkg} does not exist.')
            elif not os.path.isfile(f'{rootdir}/{pkg}/PKGBUILD'):
                raise RuntimeError(f'{pkg}/PKGBUILD does not exist.')
            elif devel is False and isvcs(pkg):  # None is treated as True in this case
                logger.warning(f'skipping {pkg}: no-devel flag is set')
            else:
                yield pkg


async def printsrcinfo_async(pkgbase):
    returncode, stdout, stderr = await run_async(['makepkg', '--printsrcinfo'],
        cwd=f'{rootdir}/{pkgbase}', stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    if returncode != 0:
        raise RuntimeError(f'could not update {pkgbase}/.SRCINFO ({returncode})\n{stderr}')
    return stdout

async def updatesrcinfo_async(pkgbase, contents=None):
    if contents is None:
        contents = await printsrcinfo_async(pkgbase)
    with open(f'{rootdir}/{pkgbase}/.SRCINFO', 'w') as fd:
        fd.write(contents)
    return contents

async def readsrcinfo_async(pkgbase, /, cache):
    if issrcinfooutdated(pkgbase):
        if cache:
            return await updatesrcinfo_async(pkgbase)
        else:
            return await printsrcinfo_async(pkgbase)
    else:
        with open(f'{rootdir}/{pkgbase}/.SRCINFO', 'r') as fd:
            return fd.read()



# Commands
def build(args):
    class Package(object):
        __slots__ = ('srcinfo', 'db')
        def __init__(self, srcinfo):
            self.srcinfo = srcinfo
            self.db = None
    class Provided(object):
        __slots__ = ('srcinfos', 'versions')
        def __init__(self):
            self.srcinfos = []
            self.versions = []

    def pkgsextrainfo(pkgs):
        srcinfos = {}
        prvds = {}
        for pkgname, pkg in pkgs.items():
            info = pkg.srcinfo
            if info['pkgbase'] not in srcinfos:
                srcinfos[info['pkgbase']] = info

            for pvd in itertools.chain(*filter(None, map(lambda k: info['packages'][pkgname].get(k), ['provides', 'provides_'+env['CARCH']]))):
                pvd, _, version = pvd.partition('=')
                pvd = prvds.setdefault(pvd, Provided())
                pvd.srcinfos.append(info)
                pvd.versions.append(version or info['pkgver'])
        return srcinfos, prvds

    def makedepsort(pkgs, srcinfos=None, prvds=None):
        if not all((srcinfos, prvds)):
            srcinfos, prvds = pkgsextrainfo(pkgs)
        ops = ('<=', '>=', '<', '=', '>')
        visited = {pkgbase: False for pkgbase in srcinfos.keys()}

        def visit(pkgbase):
            visited[pkgbase] = True
            info = srcinfos[pkgbase]

            for pkg in itertools.chain(*(info[k] for k in ['depends', 'makedepends', 'checkdepends'] if k in info)):  # dont implement it for subpackages (see https://man.archlinux.org/man/PKGBUILD.5#PACKAGE_SPLITTING)
                deppkgname, op, reqversion = next(filter(lambda x: x[1], (pkg.partition(op) for op in ops)), (pkg, '', ''))
                if deppkgname in pkgs:
                    depsrcinfos = [pkgs[deppkgname].srcinfo]
                    versions = [depsrcinfos[0]['pkgver']]
                elif deppkgname in prvds:
                    depsrcinfos = prvds[deppkgname].srcinfos
                    versions = prvds[deppkgname].versions
                else:
                    continue

                if reqversion:
                    s, v = depsrcinfos, versions
                    depsrcinfos, versions = [], []
                    for depsrcinfo, version, cmp in ((s, v, vercmp(v, reqversion)) for s,v in zip(s,v)):
                        if (cmp < 0 and '<' in op) or (cmp == 0 and '=' in op) or (cmp > 0 and '>' in op):
                            depsrcinfos.append(depsrcinfo)
                            versions.append(version)

                for depsrcinfo in depsrcinfos:
                    deppkgbase = depsrcinfo['pkgbase']
                    if not visited[deppkgbase]:
                        yield from visit(deppkgbase)

            yield info

        for pkgbase in srcinfos.keys():
            if not visited[pkgbase]:
                yield from visit(pkgbase)

    # .SRCINFO
    def getsrcinfos(pkgs):
        semaphore = asyncio.Semaphore(os.cpu_count())
        async def getsrcinfo_async(pkgbase):
            srcinfo = None
            tasks = []

            async with semaphore:
                if isvcs(pkgbase):
                    # update pkgver in PKGBUILD
                    returncode, _, stderr = await run_async(['makepkg', '--nodeps', '--skipinteg', '--noprepare', '--nobuild'],
                        cwd=f'{rootdir}/{pkgbase}', stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
                    )

                    # remove leftover files in background
                    tasks.append(asyncio.create_task(run_async(['rm', '-rf', f'{env["BUILDDIR"]}/{pkgbase}'])))

                    if returncode != 0:
                        raise RuntimeError(f'could not update {pkgbase}/PKGBUILD ({returncode})\n{stderr}')

                srcinfo = Srcinfo.parsestr(await readsrcinfo_async(pkgbase, cache=True))
                if tasks:
                    asyncio.wait(tasks)

            return srcinfo

        async def getsrcinfos_async(pkgs):
            ret = {}
            oldbuilddir, env['BUILDDIR'] = env['BUILDDIR'], f'{gettempdir()}/makepkg'
            for coro in asyncio.as_completed(map(getsrcinfo_async, pkgs)):
                info = await coro
                for pkgname in info['packages']:
                    ret[pkgname] = Package(info)
            env['BUILDDIR'] = oldbuilddir
            return ret

        return asyncio.run(getsrcinfos_async(pkgs))


    # Init
    args.pkgs = list(iterpkgs(args.pkgs, devel=args.devel))

    pacmanconf = PacmanConfig('/etc/pacman.conf')
    localdbs = [os.path.realpath(f'{s[7:]}/{k}.db') for k,v in pacmanconf.repos.items() for s in v if s.startswith('file://')]
    env.setdefault('SRCPKGDEST', rootdir)
    env.setdefault('PKGDEST', os.path.dirname(localdbs[0]))
    env.setdefault('BUILDDIR', f'{gettempdir()}/makepkg')

    pkgs = getsrcinfos(args.pkgs)
    if pkgs is None:
        return 1

    # Filter based on newer version
    for db in localdbs:
        for pkgname, version in getdbpkgs(db):
            if pkgname in pkgs:
                if vercmp(version, Srcinfo.version(pkgs[pkgname].srcinfo)) < 0:
                    pkgs[pkgname].db = db
                else:
                    logger.info(f'Skipping {pkgname}: up-to-date')
                    del pkgs[pkgname]

    # Build
    for info in makedepsort(pkgs):  # TODO allow .makepkg.conf specific for each package (export an env var with the path for the default makepkg.conf in order to be sourced, maybe in ./aur bash script). also add runmakepkg[_async] function and a script which takes care of the makepkg.conf
        os.chdir(f'{rootdir}/{info["pkgbase"]}')
        returncode, _, _ = run(['makepkg', '-src'])
        if returncode != 0:
            raise RuntimeError(f'{info["pkgbase"]} failed')

        dbs = {}
        for pkgname, archive in Srcinfo.archives(info):
            db = pkgs[pkgname].db or localdbs[0]
            dbs.setdefault(db,[]).append(archive)

        # .sig files are already in PKGDEST and are automatically detected
        for db, archives in dbs.items():
            run(['repo-add', '-R', db, *archives])
        print('='*80, end='\n\n')



def outofdate(args):
    args.pkgs = list(iterpkgs(args.pkgs, devel=args.devel))
    semaphore = asyncio.Semaphore(os.cpu_count())

    async def check_outofdate_async(pkgbase):
        pkgdir = f'{rootdir}/{pkgbase}'
        latestver_path = f'{pkgdir}/LATESTVER'

        if not os.path.exists(latestver_path):
            if not isvcs(pkgbase):
                logger.warning(f'{latestver_path} does not exist.')

        else:
            async with semaphore:
                returncode, stdout, _ = await run_async([latestver_path], cwd=pkgdir, stdout=asyncio.subprocess.PIPE)
                if returncode != 0:
                    logger.error(f'{latestver_path} failed with exit code {returncode}.')

                else:
                    srcinfo = Srcinfo.parsestr(await readsrcinfo_async(pkgbase, cache=True))
                    version = f'{srcinfo["pkgver"]}-{srcinfo["pkgrel"]}'
                    indentation = ' ' * len(pkgbase)
                    newercount = 0
                    for v in stdout.strip().splitlines():
                        v = v.split(':', maxsplit=1)[-1]
                        if vercmp(v, version) > 0:
                            newercount += 1
                            if newercount == 1:
                                print(f'{pkgbase} {version}')
                            print(indentation, v)

    return asyncio.run(waitall(map(check_outofdate_async, args.pkgs)))



# TODO
def clean(args):
    args.pkgs = iterpkgs(args.pkgs, devel=True)
    semaphore = asyncio.Semaphore(os.cpu_count())

    # TODO remove packages that are not in the database
    # TODO remove items from SRCDEST except for directories with .git (maybe also use srcinfos)
    async def clean_async():
        with os.scandir(env['SRCDEST']) as entries:
            for entry in entries:
                pass
        # returncode, stdout, stderr = await run_async(['rm', '-rf', f'{env["SRCDEST"]}/{pkgbase}'])

    return asyncio.run(waitall(clean_async))



def fix(args):
    pkgs = bool(args.pkgs)
    args.pkgs = iterpkgs(args.pkgs, devel=True)
    if not pkgs:
        args.pkgs = filter(issrcinfooutdated, args.pkgs)
    del pkgs

    semaphore = asyncio.Semaphore(os.cpu_count())

    # TODO check packages all the packages in the database for existence

    async def fixchecksums(srcinfo):
        async def getchecksum(algo, source, hashval):
            filename, protocol, url = Srcinfo.splitsource(source)
            async with semaphore:
                catcmd = f'curl -Ls \'{url.replace(chr(39), "%27")}\'' if protocol != 'local' else f'cat "{rootdir}/{srcinfo["pkgbase"]}/{url}"'
                returncode, stdout, stderr = await run_async(f'{catcmd} | {algo}sum -b',
                    shell=True, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )

            if returncode != 0:
                raise RuntimeError(f'could not compute {algo} for {filename}::{url}\n{stderr}')

            stdout = stdout[:stdout.find(' ')].lower()
            if stdout == hashval:
                return None
            return stdout

        hashvalues = set()
        oldchecksums = []
        coros = []

        # Find all checksums for sources
        for suffix in Srcinfo.archsuffixes(srcinfo):
            sources = 'source' + suffix
            if sources in srcinfo:
                for algo in Srcinfo.checksum_algos:
                    checksums = algo + 'sums' + suffix
                    if checksums in srcinfo:
                        for source, checksum in zip(srcinfo[sources], srcinfo[checksums]):
                            hashval = checksum.lower()
                            if hashval != 'skip':
                                if hashval in hashvalues:  # XXX Unlikely. This requires more complex logic when editing the PKGBUILD file. Returning an error should be good enough for now
                                    raise RuntimeError(f'{srcinfo["pkgbase"]}/PKGBUILD contains multiple checksums equal to {checksum}')
                                hashvalues.add(hashval)
                                oldchecksums.append(checksum)
                                coros.append(getchecksum(algo, source, hashval))

        # Find and replace checksum mismatches
        if not hashvalues:
            return
        del hashvalues

        replacements = sorted(filter(lambda x: x[1], zip(oldchecksums, await asyncio.gather(*coros))), key=lambda x: len(x[0]), reverse=True)
        if not replacements:
            return

        oldchecksums, _ = zip(*replacements)
        replacements = dict(replacements)

        with open(f'{rootdir}/{srcinfo["pkgbase"]}/PKGBUILD', 'r+') as fd:
            contents = re.sub('|'.join(oldchecksums), lambda m: replacements[m.group(0)], fd.read())
            fd.seek(0)
            fd.write(contents)

    async def fixpkg_async(pkgbase):
        async with semaphore:
            srcinfo = Srcinfo.parsestr(await readsrcinfo_async(pkgbase, cache=True))

        await fixchecksums(srcinfo)

        if issrcinfooutdated(pkgbase):
            await updatesrcinfo_async(pkgbase)

    return asyncio.run(waitall(map(fixpkg_async, args.pkgs)))



def main(args=sys.argv[1:]):
    argparser = argparse.ArgumentParser(description='', allow_abbrev=False)
    argparser.add_argument('--verbose', '-v', action='store_true', help='Show more info.')
    subparsers = argparser.add_subparsers()

    buildcmd = subparsers.add_parser('build', help='Build packages.')
    buildcmd.add_argument('pkgs', metavar='PKGS', nargs='*', help='Packages to build.')
    buildcmd.add_argument('--devel', action=argparse.BooleanOptionalAction, help='By default, VCS packages are included if PKGS is given, they are excluded otherwise. This overwrites the behaviour.')
    buildcmd.set_defaults(func=build)

    outofdatecmd = subparsers.add_parser('outofdate', help='Check for new versions upstream.')
    outofdatecmd.add_argument('pkgs', metavar='PKGS', nargs='*', help='Packages to check.')
    outofdatecmd.add_argument('--devel', action=argparse.BooleanOptionalAction, help='By default, VCS packages are included if PKGS is given, they are excluded otherwise. This overwrites the behaviour.')
    outofdatecmd.set_defaults(func=outofdate)

    fixcmd = subparsers.add_parser('fix', help='Fix packages (e.g. update .SRCINFO files).')
    fixcmd.add_argument('pkgs', metavar='PKGS', nargs='*', help='Packages to fix.')
    fixcmd.set_defaults(func=fix)

    # TODO cleancmd

    args = argparser.parse_args(args)

    if args.verbose:
        logger.setLevel(logging.INFO)

    if 'func' in args:
        try:
            return args.func(args)
        except RuntimeError as e:
            e = str(e)
            if e:
                logger.error(e)
            else:
                raise

    return 1



if __name__ == '__main__':
    logger.setLevel(logging.WARNING)
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter('{levelname}: {message}', style='{'))
    logger.addHandler(handler)
    sys.exit(main())
