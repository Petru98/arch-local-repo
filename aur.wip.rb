#!/usr/bin/ruby
require 'etc'
require 'json'
require 'optparse'
require 'tmpdir'
require 'concurrent'


def stat(path)
  return File.stat(path)
rescue Errno::ENOENT
  return nil
end
def lstat(path)
  return File.lstat(path)
rescue Errno::ENOENT
  return nil
end

def mtimecmp(path1, path2)
  begin
    t1 = File.stat(path1).mtime
  rescue Errno::ENOENT
    t1 = Time.at(0)
  end
  begin
    t2 = File.stat(path2).mtime
  rescue Errno::ENOENT
    t2 = Time.at(0)
  end
  return t1 - t2
end

def isdigit(ch)
    return ch =~ /[[:digit:]]/
end



class Srcinfo < Hash
    @checksum_algos = %w[md5 sha1 sha224 sha256 sha384 sha512 b2]


    class << self
        attr_accessor :checksum_algos

        @@_array_keys_pattern = %r{^
            pkgname|arch|groups|license|noextract|options|backup|validpgpkeys|
            depends|makedepends|checkdepends|optdepends|
            source(_.+)?|conflicts(_.+)?|provides(_.+)?|replaces(_.+)?|
            #{Srcinfo.checksum_algos.map{|x| "#{x}sums"}.join('|')}
        $}x
        def array?(key)
            return key =~ @@_array_keys_pattern
        end

        @@_overriddable_keys = %r{^
            pkgdesc|url|install|changelog|
            arch|groups|license|noextract|options|backup|
            depends(_.+)?|optdepends(_.+)?|
            conflicts(_.+)?|provides(_.+)?|replaces(_.+)?
        $}x
        def canbeoverriden(key)
            return key =~ @@_overriddable_keys
        end


        def splitsource(source)
            filename, _, url = source.rpartition('::')

            i = url.index('://')
            if i.nil?
                protocol = 'local'
            else
                j = url[0,i].index('+')
                if j.nil?
                    protocol = url[0,i]
                else
                    protocol = url[0,j]
                    url = url[j+1...url.length]
                end
            end

            if filename.empty?
                if protocol == 'local'
                    filename = url.dup
                    while filename.chomp!('/') ; end
                    filename = filename.rpartition('/')[2]
                else
                    filename = url.partition('#')[0].partition('?')[0]
                    while filename.chomp!('/') ; end
                    filename = filename.rpartition('/')[2]
                    filename.delete_suffix!('.git') if protocol == 'git'
                end
            end

            return filename, protocol, url
        end
    end


    def archsuffixes
        r = ['']
        r.concat(self['arch'].map {|x| "_#{x}"}) if self['arch'][0] != 'any'
        return r
    end

    def version
        return "#{self.key?('epoch') ? "#{self['epoch']}:" : ''}#{self['pkgver']}-#{self['pkgrel']}"
    end

    def archives(makepkgconf, &blk)
        e = Enumerator.new do |yielder|
            pkgdest = makepkgconf.get('PKGDEST')
            pkgext = makepkgconf.get('PKGEXT')
            carch = makepkgconf.get('CARCH')
            version = self.version
            self['packages'].each_key do |pkgname|
                arch = (self['arch'][0] == 'any' ? 'any' : carch)
                yielder << [pkgname, "#{pkgdest}/#{pkgname}-#{version}-#{arch}#{pkgext}"]
            end
        end

        return e unless blk
        e.each(&blk)
    end


    # TODO: make static
    def parse(lines)
        self.clear
        self['packages'] = {}
        info = self
        lines.each do |line|
            next if line =~ /^\s*(?:#.*\s*)?$/
            m = /^\s*([^=\s]+?)\s*=\s*(.+?)\s*$/.match(line)
            raise "invalid srcinfo line '#{line}'" if m.nil?
            k,v = m.captures

            if k == 'pkgbase'
                raise 'pkgbase declared more than once' if self.key?('pkgbase')
                raise 'pkgbase declared after pkgname' if !info.equal?(self)
                self['pkgbase'] = v

            elsif k == 'pkgname'
                info = {'pkgname' => v}
                self['packages'][v] = info

            elsif Srcinfo.array?(k)
                raise "#{k} can only be in pkgbase" if !info.equal?(self) && !Srcinfo.canbeoverriden(k)
                info[k] ||= []
                info[k].append(v)

            else
                raise "#{k} can only be in pkgbase" if !info.equal?(self) && !Srcinfo.canbeoverriden(k)
                raise "#{k} declared more than once" if info.key?(k)
                info[k] = v
            end
        end

        raise 'arch not specified' if !self.key?('arch')
        raise 'package cannot be arch-specific and arch-independent simultaneously' if self['arch'].length >= 2 && self['arch'].include?('any')
        self.archsuffixes.each do |suffix|
            sources = "source#{suffix}"
            next unless self.key?(sources)
            Srcinfo.checksum_algos.each do |algo|
                checksums = "#{algo}sums#{suffix}"
                next unless self.key?(checksums)
                raise "#{sources} and #{checksums} have different lengths" if self[sources].length != self[checksums].length
            end
        end

        self.each do |k,v|
            next unless Srcinfo.canbeoverriden(k)
            self['packages'].each_value do |info|
                info[k] = v unless info.key?(k)
            end
        end

        return self
    end

    def parsefile(path)
        File.new(path) do |fd|
            return self.parse(fd)
        end
    end
    def parsestr(str)
        return self.parse(str.each_line)
    end
end



def versplit(version)
    return version.scan(/(?>[[:alpha:]]+) | (?>[1-9][[:digit:]]*) | 0(?=\z|[^[:digit:]])/x)
end
def vercmp(v1, v2)
    v1 = versplit(v1)
    v2 = versplit(v2)
    n = [v1.size, v2.size].min

    (0...n).each do |i|
        if isdigit(v1[i])
            return 1 unless isdigit(v2[i])
        else
            return -1 if isdigit(v2[i])
        end
        r = v1[i].length <=> v2[i].length
        r = v1[i] <=> v2[i] if r == 0
        return r if r != 0
    end

    return v1.size < v2.size ? (isdigit(v1[n]) ?  1 : -1)
        :  v1.size > v2.size ? (isdigit(v2[n]) ? -1 :  1)
        :  0
end


def vcs?(pkgname)
    return pkgname.end_with?('-git','-svn','-bzr','-hg','-cvs','-nightly')
end



class Aur
    @log = Logger.new($stderr, level: Logger::INFO, formatter: proc {|severity, _datetime, _progname, msg|
        "#{severity}: #{msg}\n"
    })

    @rootdir = __dir__
    @tmpdir = Dir.tmpdir

    @CARCH_DEFAULT = Etc.uname[:machine]
    @SRCDEST_DEFAULT = "#{Dir.home}/.cache/aur"
    @PKGEXT_DEFAULT = '.pkg.tar.zst'
    @SRCEXT_DEFAULT = '.src.tar.gz'
    @SRCPKGDEST_DEFAULT = @rootdir
    @BUILDDIR_DEFAULT = "#{@tmpdir}/makepkg"


    class << self
        attr_accessor :log, :rootdir, :tmpdir,
            :CARCH_DEFAULT, :SRCDEST_DEFAULT, :PKGEXT_DEFAULT, :SRCEXT_DEFAULT, :SRCPKGDEST_DEFAULT, :BUILDDIR_DEFAULT


        def srcinfo_outdated?(pkgbase)
            path = "#{Aur.rootdir}/#{pkgbase}"
            return mtimecmp("#{path}/.SRCINFO", "#{path}/PKGBUILD") < 0
        end

        def generate_srcinfo(pkgbase)
            data = IO.popen(['makepkg', '--printsrcinfo'], chdir: "#{Aur.rootdir}/#{pkgbase}", &:read)
            raise "could not generate srcinfo for #{pkgbase}" unless $?.success?
            return data
        end
        def update_srcinfo(pkgbase, contents = nil)
            contents ||= generate_srcinfo(pkgbase)
            File.write("#{Aur.rootdir}/#{pkgbase}/.SRCINFO", contents)
            return contents
        end
        def read_srcinfo(pkgbase, cache: true)
            if srcinfo_outdated?(pkgbase)
                return cache ? update_srcinfo(pkgbase) : generate_srcinfo(pkgbase)
            end
            return File.read("#{Aur.rootdir}/#{pkgbase}/.SRCINFO")
        end


        def getlocaldbs(filename, section = nil)
            dbs = []
            File.open(filename) do |fd|
                fd.each do |line|
                    line.strip!
                    if line[0] == '['
                        section = line[1...line.length-1]
                    else
                        k,_,v = line.partition(/\s*=\s*/)
                        case k
                        when 'Include' then dbs.concat(getlocaldbs(v, section)) if v != '/etc/pacman.d/mirrorlist'
                        when 'Server' then dbs.append(File.realpath("#{v[7...nil]}/#{section}.db")) if v.start_with?('file://')
                        end
                    end
                end
            end
            return dbs
        end

        def iterdbpkgs(db, &blk)
            e = Enumerator.new do |yielder|
                IO.popen(['tar', '-t', '-f', db]) do |fd|
                    fd.each(chomp: true) do |line|
                        next unless line.index('/') == line.length - 1
                        line.chop!
                        i = line.rindex('-', line.rindex('-') - 1)
                        pkgname = line[0...i]
                        version = line[i+1...nil]
                        yielder << [pkgname, version]
                    end
                end
            end

            return r unless blk
            e.each(&blk)
        end

        def iterpkgs(pkgs, devel: nil, &blk)
            e = Enumerator.new do |yielder|
                if pkgs.nil? || pkgs.empty?
                    Dir.each_child(Aur.rootdir) do |pkgbase|
                        next unless File.exist?("#{Aur.rootdir}/#{pkgbase}/PKGBUILD")
                        if devel || !vcs?(pkgbase)  # nil is treated as false in this case
                            yielder << pkgbase
                        else
                            Aur.log.warn("skipping #{pkgbase}: no-devel flag is set")
                        end
                    end
                else
                    pkgs.each do |pkgbase|
                        raise "#{pkgbase}/PKGBUILD does not exist" unless File.exist?("#{Aur.rootdir}/#{pkgbase}/PKGBUILD")
                        if devel == false || !vcs?(pkgbase)  # nil is treated as true in this case
                            yielder << pkgbase
                        else
                            Aur.log.warn("skipping #{pkgbase}: no-devel flag is set")
                        end
                    end
                end
            end

            return e unless blk
            e.each(&blk)
        end
    end
end



class MakepkgConf
    def initialize(path = nil)
        unless path.instance_of?(String)
            if path.instance_of?(Enumerable)
                # nothing
            elsif path.nil?
                path = []
            else
                raise TypeError("argument is #{path.class} instead of String, Enumerable, or nil")
            end

            path = path.chain([
                "#{Aur.rootdir}/makepkg.conf",
                "#{Dir.home}/.config/pacman/makepkg.conf",
                "#{Dir.home}/.makepkg.conf"
            ]).find('/etc/makepkg.conf') {|p| File.exist?(p)}
        end

        data = IO.popen(['env', '-i', "#{Aur.rootdir}/print-makepkgconf", path], &:read)
        raise "could not load #{path}" unless $?.success?
        @data = JSON.parse(data)
    end

    def get(key, default = nil)
        return ENV[key] || @data[key] || default
    end
    def setdefault(key, default)
        return self.get(key) || ENV[key] = default
    end
end



class Build
    def initialize(pkgs, devel: nil)
        threadpool = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: Concurrent.processor_count)
        futures = Aur.iterpkgs(pkgs, devel: devel).map do |pkgbase|
            Concurrent::Future.execute(executor: threadpool) do
                if vcs?(pkgbase)
                    system({'BUILDIR'=>"#{Aur.tmpdir}/makepkg"}, 'makepkg', '--nodeps', '--skipinteg', '--noprepare', '--nobuild',
                        chdir: "#{Aur.rootdir}/#{pkgbase}",
                        out: '/dev/null',
                        exception: true
                    )
                    system('rm', '-rf', "#{ENV['BUILDDIR']}/#{pkgbase}")
                end
                Srcinfo.new.parsestr(Aur.read_srcinfo(pkgbase, cache: true))

            rescue RuntimeError => e
                Aur.log.error(e.message)
            rescue StandardError => e
                $stderr.puts(e.message)
                $stderr.puts(e.backtrace.inspect)
            end
        end

        @localdbs = Aur.getlocaldbs('/etc/pacman.conf')
        @makepkgconf = MakepkgConf.new
        @makepkgconf.setdefault('CARCH'     , Aur.CARCH_DEFAULT)
        @makepkgconf.setdefault('SRCDEST'   , Aur.SRCDEST_DEFAULT)
        @makepkgconf.setdefault('PKGEXT'    , Aur.PKGEXT_DEFAULT)
        @makepkgconf.setdefault('SRCEXT'    , Aur.SRCEXT_DEFAULT)
        @makepkgconf.setdefault('SRCPKGDEST', Aur.SRCPKGDEST_DEFAULT)
        @makepkgconf.setdefault('BUILDDIR'  , Aur.BUILDDIR_DEFAULT)
        @makepkgconf.setdefault('PKGDEST'   , File.dirname(@localdbs[0]))

        @pkgs = {}
        futures.map do |future|
            srcinfo = future.value
            raise future.reason.to_s if future.rejected?
            srcinfo['packages'].each_key do |pkgname|
                @pkgs[pkgname] = {:srcinfo => srcinfo, :db => nil}
            end
        end

    ensure
        threadpool.shutdown
        threadpool.wait_for_termination
    end


    def makedepsort(&blk)
        e = Enumerator.new do |yielder|
            srcinfos = {}
            prvds = {}
            @pkgs.each do |pkgname, pkg|
                info = pkg[:srcinfo]
                srcinfos[info['pkgbase']] ||= info
                ['provides', "provides_#{@makepkgconf.get('CARCH')}"].filter_map{|k| info['packages'][pkgname][k]}.flatten.each do |pvd|
                    pvd, _, version = pvd.partition('=')
                    prvds[pvd] ||= {:srcinfos => [], :versions => []}
                    prvds[pvd][:srcinfos].append(info)
                    prvds[pvd][:versions].append(version != '' ? version : info['pkgver'])
                end
            end

            ops = ['<=', '>=', '<', '=', '>']
            visited = {}

            visit = ->(pkgbase) do
                visited[pkgbase] = true
                info = srcinfos[pkgbase]

                # don't implement it for subpackages (see https://man.archlinux.org/man/PKGBUILD.5#PACKAGE_SPLITTING)
                ['depends', 'makedepends', 'checkdepends'].filter_map {|k| info[k]}.flatten.each do |pkg|
                    op = ops.find(->{''}) {|x| pkg.include?(x)}
                    deppkgname, _, reqversion = (op != '' ? pkg.partition(op) : [pkg, '', ''])

                    if @pkgs.key?(deppkgname)
                        depsrcinfos = [@pkgs[deppkgname][:srcinfo]]
                        versions = [depsrcinfos[0]['pkgver']]
                    elsif prvds.key?(deppkgname)
                        depsrcinfos = prvds[deppkgname][:srcinfos]
                        versions = prvds[deppkgname][:versions]
                    else
                        next
                    end

                    if reqversion != ''
                        depsrcinfos, _versions = depsrcinfos.zip(versions).select do |_s,v|
                            cmp = vercmp(v, reqversion)
                            (cmp < 0 && op[0] == '<') || (cmp == 0 && op[0] == '=') || (cmp > 0 && op[0] == '>')
                        end.transpose
                    end

                    depsrcinfos.each do |depsrcinfo|
                        visit.call(depsrcinfo['pkgbase']) unless visited[depsrcinfo['pkgbase']]
                    end
                end

                yielder << info
            end

            srcinfos.each_key do |pkgbase|
                visit.call(pkgbase) unless visited[pkgbase]
            end
        end

        return e unless blk
        e.each(&blk)
    end


    def call
        # Filter based on newer version
        @localdbs.each do |db|
            Aur.iterdbpkgs(db) do |pkgname, version|
                next unless @pkgs.key?(pkgname)
                if vercmp(version, @pkgs[pkgname][:srcinfo].version) < 0
                    @pkgs[pkgname][:db] = db
                else
                    Aur.log.info("Skipping #{pkgname}: up-to-date")
                    @pkgs.delete(pkgname)
                end
            end
        end

        # Build
        self.makedepsort do |info|
            system('makepkg', '-srcf', chdir: "#{Aur.rootdir}/#{info['pkgbase']}", exception: true)

            dbs = {}
            info.archives(@makepkgconf) do |pkgname, archive|
                db = @pkgs[pkgname][:db] || @localdbs[0]
                dbs[db] ||= []
                dbs[db].append(archive)
            end

            # .sig files are already in PKGDEST and are automatically detected
            dbs.each do |db, archives|
                system('repo-add', '-R', db, *archives, exception: true)
            end

            puts('#'*80, "\n")
        end
    end
end



class Fix
    def initialize(pkgs)
        empty_pkgs = pkgs.nil? || pkgs.empty?
        pkgs = Aur.iterpkgs(pkgs, devel: true)
        pkgs = pkgs.filter {|pkgbase| Aur.srcinfo_outdated?(pkgbase)} if empty_pkgs
        @pkgs = pkgs.to_a
    end


    def fixchecksums(srcinfo)
        hashvalues = [].to_set
        oldchecksums = []
        replacements = {}

        srcinfo.archsuffixes.each do |suffix|
            sources = "source#{suffix}"
            next unless srcinfo.key?(sources)

            Srcinfo.checksum_algos.each do |algo|
                checksums = "#{algo}sums#{suffix}"
                next unless srcinfo.key?(checksums)

                srcinfo[sources].zip(srcinfo[checksums]) do |source, checksum|
                    next if checksum.casecmp?('skip')
                    # XXX Unlikely. This requires more complex logic when editing the PKGBUILD file. Returning an error should be good enough for now
                    raise "#{srcinfo['pkgbase']}/PKGBUILD contains multiple checksums equal to #{checksum}" if hashvalues.add?(checksum.downcase).nil?

                    _filename, protocol, url = Srcinfo.splitsource(source)
                    if protocol != 'local'
                        status = IO.popen(['curl', '-Ls', '-o', '/dev/null', '-I', '-w', '%{http_code}', url], &:read)
                        raise "could not do a HEAD request for #{url}" unless $?.success?
                        raise "got status #{status} for #{url}" if status.to_i >= 300
                        catcmd = "curl -Ls '#{url.sub("'", '%27')}'"
                    else
                        catcmd = "cat '#{rootdir}/#{srcinfo['pkgbase']}/#{url}'"
                    end
                    newchecksum = `#{catcmd} | #{algo}sum -b`
                    raise "could not download #{url} or compute it's checksum" unless $?.success?

                    newchecksum = newchecksum[0,newchecksum.index(' ')].downcase
                    next if newchecksum.casecmp?(checksum)
                    oldchecksums.append(checksum)
                    replacements[checksum] = newchecksum
                end
            end
        end

        unless replacements.empty?
            oldchecksums.sort!.reverse!
            File.open("#{Aur.rootdir}/#{srcinfo['pkgbase']}/PKGBUILD", 'r+') do |fd|
                contents = fd.read
                contents.gsub!(/#{oldchecksums.join('|')}/) {|m| replacements[m]}
                fd.seek(0)
                fd.truncate(0)
                fd.write(contents)
            end
        end
    end


    def call
        threadpool = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: Concurrent.processor_count)
        @pkgs.each do |pkgbase|
            threadpool.post(pkgbase) do |pkgbase|
                srcinfo = Srcinfo.new.parsestr(Aur.read_srcinfo(pkgbase, cache: true))
                self.fixchecksums(srcinfo)
                Aur.update_srcinfo(pkgbase) if Aur.srcinfo_outdated?(pkgbase)

            rescue RuntimeError => e
                Aur.log.error(e.message)
            rescue StandardError => e
                $stderr.puts(e.message)
                $stderr.puts(e.backtrace.inspect)
            end
        end

    ensure
        threadpool.shutdown
        threadpool.wait_for_termination
    end
end



if __FILE__ == $0
    options = {}

    global = OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options] [subcommand [options]]"
        opts.on('-q', '--quiet', 'Only print warnings and errors') do |q|
            if q
                Aur.log.level = Logger::WARN
            end
        end
        opts.separator ''
        opts.separator <<-"HELP"
Commands:
    build

See '#{$0} COMMAND --help' for more information on a specific command.
        HELP
    end


    subcommands = {
        'build' => {
            :parser => OptionParser.new do |opts|
                opts.banner = "Usage: #{$0} build [options] [PKGS]"
                opts.on('--[no-]devel', 'By default, VCS packages are included if PKGS is given, they are excluded otherwise. This overwrites the behaviour.') do |d|
                    options[:devel] = d
                end
            end,
            :call => ->{Build.new(ARGV, **options).call}
        },
        'fix' => {
            :parser => OptionParser.new do |opts|
                opts.banner = "Usage: #{$0} fix [options] [PKGS]"
            end,
            :call => ->{Fix.new(ARGV, **options).call}
        }
    }


    global.order!
    command = ARGV.shift

    if command
        if subcommands.key?(command)
            subcommands[command][:parser].order!
            subcommands[command][:call].call
        else
            puts("error: invalid command #{command}")
            puts(global.help)
            puts
        end
    else
        puts(global.help)
        puts
    end
end
