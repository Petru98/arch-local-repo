#!/usr/bin/perl
# Dependencies: perl-coro

use strict;
use warnings;
# use diagnostics;
use v5.34;

use POSIX qw(WNOHANG);
# use Symbol 'qualify_to_ref';
use File::Spec::Functions qw(rel2abs);
# use List::Util qw(first any);

use POE;

# use Coro;
# use Coro::AnyEvent;
# use EV;
# AnyEvent::detect;

# use Data::Dumper;
# $Data::Dumper::Deparse = 1;


# use Benchmark qw(:all);

# open(my $fd, '<', '/proc/cpuinfo') or die "/proc/cpuinfo: $!";
# my @lines = <$fd>;
# close($fd);
# timethese(300000, {
#     1 => sub {return scalar(map(/^processor/, @lines));},
#     2 => sub {return scalar(grep(/^processor/, @lines));},
#     3 => sub {return scalar(map {rindex($_, 'processor', 0) != -1 ? (1) : ()} @lines);},
#     4 => sub {return scalar(grep {rindex($_, 'processor', 0) != -1} @lines);}
# });



sub isdigit {
    return ord $_[0] >= ord '0' && ord $_[0] <= ord '9';
}
# sub islower {
#     return ord $_[0] >= ord 'a' && ord $_[0] <= ord 'z';
# }
# sub isupper {
#     return ord $_[0] >= ord 'A' && ord $_[0] <= ord 'Z';
# }
# sub isalpha {
#     return ord $_[0] >= ord 'a' && ord $_[0] <= ord 'z'
#         || ord $_[0] >= ord 'A' && ord $_[0] <= ord 'Z';
# }
# sub isalnum {
#     return ord $_[0] >= ord '0' && ord $_[0] <= ord '9'
#         || ord $_[0] >= ord 'a' && ord $_[0] <= ord 'z'
#         || ord $_[0] >= ord 'A' && ord $_[0] <= ord 'Z';
# }

sub basename {
    my @base = ($_[0] =~ m'([^/]+)/*\z');
    return $base[0] ? $base[0] : '.';
}
sub dirname {
    my @dir = ($_[0] =~ m'\A(?:(.*)/)?[^/]+/*\z');
    return $dir[0] ? $dir[0] : '.';
}
sub tmpdir {
    for($ENV{'TMPDIR'}, '/tmp', '/var/tmp') {
        return $_ if($_ && -w $_);
    }
    return '.';
}

sub cpucount {
    open(my $fd, '<', '/proc/cpuinfo') or die "/proc/cpuinfo: $!";
    return scalar(grep {rindex($_, 'processor', 0) != -1} <$fd>);
}


my $rootdir = rel2abs(dirname(__FILE__));
my $tmpdir = tmpdir();



my @srcinfo_checksum_algos = ('md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512', 'b2');

sub srcinfo_isarray {
    state $pattern = qr/^
        pkgname|arch|groups|license|noextract|options|backup|validpgpkeys|
        depends|makedepends|checkdepends|optdepends|
        source(_.+)?|conflicts(_.+)?|provides(_.+)?|replaces(_.+)?|
        @{[join('|', map {$_ . 'sums'} @srcinfo_checksum_algos)]}
    $/nx;
    return $_[0] =~ $pattern ;
}
sub srcinfo_canbeoverriden {
    state $pattern = qr/^
        pkgdesc|url|install|changelog|
        arch|groups|license|noextract|options|backup|
        depends(_.+)?|optdepends(_.+)?|
        conflicts(_.+)?|provides(_.+)?|replaces(_.+)?
    $/nx;
    return $_[0] =~ $pattern ;
}

sub srcinfo_archsuffixes {
    if($_[0]->{'arch'}->[0] eq 'any') {
        return ('');
    }
    return ('', map { '_' . $_ } @{$_[0]->{'arch'}});
}


sub srcinfo_parse {
    state $ignoredpattern = qr/^\s*(?:#.*\s*)?$/;
    state $kvpattern = qr/^\s*([^=\s]+?)\s* = \s*(.+?)\s*$/x;
    my %srcinfo = ();
    my $info = \%srcinfo;

    for my $line (@{$_[0]}) {
        if($line =~ $ignoredpattern) {
            # next;
        }
        elsif($line =~ $kvpattern) {
            my ($k, $v) = ($1, $2);

            if($k eq 'pkgbase') {
                die "pkgbase declared more than once" if(exists $srcinfo{'pkgbase'});
                die "pkgbase declared after pkgname" if($info != \%srcinfo);
                $srcinfo{'pkgbase'} = $v;
            }
            elsif($k eq 'pkgname') {
                $srcinfo{'packages'}{$v} = {pkgname => $v};
                $info = $srcinfo{'packages'}{$v};
            }
            elsif(srcinfo_isarray($k)) {
                die "$k can only be in pkgbase" if($info != \%srcinfo && !srcinfo_canbeoverriden($k));
                push(@{$info->{$k}}, $v);
            }
            else {
                die "$k can only be in pkgbase" if($info != \%srcinfo && !srcinfo_canbeoverriden($k));
                die "$k declared more than once" if(exists $info->{$k});
                $info->{$k} = $v;
            }
        }
        else {
            print 'ERROR ', "\n";
        }
    }

    die "arch not specified" if(!exists $srcinfo{'arch'});
    die "package cannot be arch-specific and arch-independent simultaneously" if(scalar @{$srcinfo{'arch'}} >= 2 && grep {$_ eq 'any'} @{$srcinfo{'arch'}});
    # for my $suffix (srcinfo_archsuffixes(\%srcinfo)) {
    #     my $sources = 'source' . $suffix;
    #     if(exists $srcinfo{$sources}) {
    #         for my $algo (@srcinfo_checksum_algos) {
    #             my $checksums = $algo . 'sums' . $suffix;
    #             if(exists $srcinfo{$checksums}) {
    #                 if(scalar @{$srcinfo{$sources}} != scalar @{$srcinfo{$checksums}}) {
    #                     die "$sources and $checksums have different lengths";
    #                 }
    #             }
    #         }
    #     }
    # }

    while(my($k, $v) = each %srcinfo) {
        if(srcinfo_canbeoverriden($k)) {
            for my $info (values %{$srcinfo{'packages'}}) {
                if(!exists $info->{$k}) {
                    $info->{$k} = $v;
                }
            }
        }
    }

    return \%srcinfo;
}

sub srcinfo_parsefile {
    open(SRCINFO, '<', $_[0]) || die "${_[0]}: $!";
    my @lines = <SRCINFO>;
    close(SRCINFO);
    srcinfo_parse(\@lines);
}
sub srcinfo_parsestr {
    my @lines = split("\n", $_[0]);
    srcinfo_parse(\@lines);
}



sub versplit {
    return $_[0] =~ / [[:alpha:]]++ | [1-9][[:digit:]]*+ | 0(?=\z|[^[:digit:]]) /gx;
}

sub vercmp {
    my @a = versplit($_[0]);
    my @b = versplit($_[1]);
    my $n = (scalar @a <= scalar @b ? scalar @a : scalar @b);
    # say Dumper([@_], \@a, \@b);

    for my $i (0..$n-1) {
        if(isdigit $a[$i]) {
            return 1 unless(isdigit $b[$i]);
        } else {
            return -1 if(isdigit $b[$i]);
        }
        my $r = (length $a[$i] <=> length $b[$i] || $a[$i] cmp $b[$i]);
        return $r if($r);
    }

    return scalar @a > scalar @b ? (isdigit $a[$n] ?  1 : -1)
        :  scalar @a < scalar @b ? (isdigit $b[$n] ? -1 :  1)
        :  0;
}

sub isvcs {
    my $pkgname = $_[0];
    for('-git','-svn','-bzr','-hg','-cvs','-nightly') {
        return 1 if rindex($pkgname, $_) != -1;
    }
    return 0;
}


# print Dumper(srcinfo_parsefile('cli11/.SRCINFO')), "\n";

# {
#     local $/;
#     open(SRCINFO, '<', 'cli11/.SRCINFO');
#     srcinfo_parsestr(<SRCINFO>);
#     close(SRCINFO);
# }



# Shared code
my $cpucount = cpucount;
my @pending_pids;
my @running_pids;
my @done_pids;

sub addchld {

}
$SIG{CHLD} = sub {
    say 'SIGCHLD';
    # local ($!, $?);
    # while((my $pid = waitpid(-1, WNOHANG)) > 0) {
    #     for my $i (0..scalar @running_pids - 1) {
    #         if($running_pids[$i][0] == $pid) {
    #             push @done_pids, $running_pids[$i];
    #             $running_pids[$i] = $running_pids[-1] if(scalar @running_pids > 1);
    #             pop @running_pids;
    #             last;
    #         }
    #     }
    # }
};

sub _launch ($@) {
    my $preparefunc = \&{shift @_};
    my $pid = fork();
    die "fork: $!" if(!defined $pid);

    if($pid == 0) {
        $preparefunc->();
        exec(@_);
        die "exec: ", $_[0], ": $!";
    }

    return $pid;
}
sub launch {
    return _launch sub {}, @_;
}
sub launch1 (&@) {
    return _launch @_;
}
sub run_async (&@) {
    if(scalar @running_pids == cpucount) {
        push @pending_pids,
    }
    my $pid = _launch @_;
    push @running_pids, $pid;
    return $pid;
}

my $pid = launch 'echo', 'abc';
# say waitpid -1, 0;
sleep 2;
say waitpid(-1, WNOHANG);
say $?, ' ', $!;

# sub run_async (&@) {
#     my $pid = fork();
#     die "fork: $!" if(!defined $pid);
#     if($pid == 0) {
#         my $preparefunc = \&{shift @_};
#         $preparefunc->();
#         exec(@_);
#         die "exec: ", $_[0], ": $!";
#     }

#     # my $w = AnyEvent->child(pid => $pid, cb => Coro::rouse_cb);
#     # my ($rpid, $rstatus) = Coro::rouse_wait;
#     my $rpid;
#     Coro::cede while(($rpid = waitpid($pid, WNOHANG)) == 0);
#     my $rstatus = $?;
#     return $rstatus;
# }
# sub run_out_async (&@) {
#     pipe(my $or, my $ow) || die "pipe: $!";
#     my $pid = fork();
#     die "fork: $!" if(!defined $pid);
#     if($pid == 0) {
#         close($or);
#         open(STDOUT, ">&", $ow) || die "dup: $!";
#         close($ow);
#         my $preparefunc = \&{shift @_};
#         $preparefunc->();
#         exec(@_);
#         die "exec: ", $_[0], ": $!";
#     }

#     close($ow);
#     my $stdout = '';
#     my $current = $Coro::current;
#     my $done = 0;
#     my $w ;
#     $w = AnyEvent->io(fh => $or, poll => 'r', cb => sub {
#         my $bytes = sysread($or, $stdout, 4096, length($stdout));
#         die "sysread: $!" if(!defined $bytes);
#         if($bytes == 0) {
#             $done = 1;
#             $current->ready;
#             undef $w;
#         }
#     });

#     Coro::schedule while(!$done);

#     my $rpid;
#     Coro::cede while(($rpid = waitpid($pid, WNOHANG)) == 0);
#     my $rstatus = $?;
#     say $!;
#     close($or);
#     say "rpid = $rpid";
#     say "rstatus = $rstatus";
#     say "stdout = '$stdout'";

#     # $w = AnyEvent->child(pid => $pid, cb => Coro::rouse_cb);
#     # my ($rpid, $rstatus) = Coro::rouse_wait;
#     return $rstatus, $stdout;
# }

sub getpkgs {
    if(scalar @_ == 0) {
        my @pkgs;
        opendir(DIR, $rootdir) || die "$rootdir: $!";
        while(readdir(DIR)) {
            my $path = "$rootdir/$_";
            next if(($_ eq '.') || ($_ eq '..') || (! -d $path));
            push(@pkgs, $_) if(-f "$path/PKGBUILD");
        }
        closedir(DIR);
        return wantarray ? @pkgs : \@pkgs;
    }
    else {
        for(@_) {
            (-f "$rootdir/PKGBUILD") || die "file $rootdir/PKGBUILD does not exist";
        }
        return wantarray ? @_ : \@_;
    }
}

sub getlocaldbs {
    state $section_pattern = qr/^\s* \[([^\]]+)\] \s*$/x;
    state $field_pattern = qr/^\s* ([^=\s]+) (?:\s*=\s* (.*?) \s*)? $/x;

    my ($filename, $section) = @_;
    my @dbs;
    my $fd;
    open($fd, '<', $filename) || die "$filename: $!";

    while(<$fd>) {
        chomp;
        if(/$section_pattern/) {
            $section = $1;
        }
        elsif(/$field_pattern/) {
			my($k, $v) = ($1, $2);
			if($k eq 'Include') {
                push(@dbs, getlocaldbs($v, $section)) if($v ne '/etc/pacman.d/mirrorlist');
			}
            elsif($k eq 'Server') {
                push(@dbs, "@{[substr($v,7)]}/$section.db") if(rindex($v, 'file://', 0) != -1);
            }
		}
    }

    close($fd);
    return wantarray ? @dbs : \@dbs;
}

sub compute_srcinfo_async {

}



sub build {
    sub getsrcinfos {
        my $ret = {};

        # my $semaphore = new Coro::Semaphore(cpucount());
        # my @threads;
        # push(@threads, (Coro::async {
        #     my $guard = $semaphore->guard;
        #     my $pkgbase = $_[0];
        #     if(isvcs($pkgbase)) {
        #         # update pkgver in PKGBUILD
        #         my $status = run_async {chdir("$rootdir/$pkgbase") || die "chdir: $!\n";}
        #             ('echo', 'makepkg', '--nodeps', '--skipinteg', '--noprepare', '--nobuild');

        #         die "could not update $pkgbase/PKGBUILD ($status)\n" if($status);
        #         launch {} ('echo', 'rm', '-rf', "$ENV{'BUILDDIR'}/$pkgbase");
        #     }
        #     say $pkgbase, ' output: ', run_out_async(sub {}, 'echo', '-n', 'abc ');
        # } $_)) for(@_);
        # $_->join() for(@threads);



        return $ret;
    }


    my @pkgs = getpkgs(@_);
    my @localdbs = getlocaldbs('/etc/pacman.conf');
    $ENV{'SRCPKGDEST'} //= $rootdir;
    $ENV{'PKGDEST'} //= dirname($localdbs[0]);
    $ENV{'BUILDDIR'} //= "$tmpdir/makepkg";

    my $srcinfos = getsrcinfos(@pkgs);
}

build();
