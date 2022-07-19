with Utility; use Utility;

with Ada.Strings.Unbounded,
     Ada.Strings.Unbounded.Hash,
     Ada.Containers.Vectors,
     Ada.Containers.Hashed_Maps
     ;
use  Ada.Strings.Unbounded,
     Ada.Containers;

with Interfaces.C.Strings;
use  Interfaces.C,
     Interfaces.C.Strings;


package Alpm is
    Not_KV_Error: exception;
    Unknown_Key_Error: exception;
    Key_Context_Error: exception;
    Repeated_Key_Error: exception;
    Repeated_Value_Error: exception;


    function Vercmp(a, b: chars_ptr) return int
        with Import        => True,
             Convention    => C,
             External_Name => "alpm_pkg_vercmp";
    function Vercmp(a, b: String) return Integer;
    function Vercmp(a, b: Unbounded_String) return Integer;

    function Is_VCS(pkgname: String) return Boolean;
    function Is_VCS(pkgname: Unbounded_String) return Boolean;

    function Get_Local_DBs(path: String) return String_Vectors.Vector;

    procedure Srcinfo_Split_Source(src: String; filename, protocol, url: in out Unbounded_String);


    type Pkgver_CmpOp is (Eq, Lt, Gt, Le, Ge);
    function Value(s: String) return Pkgver_CmpOp;

    type Pkgver_SemiRange is record
        op: Pkgver_CmpOp;
        ver: Unbounded_String;
    end record;
    function Intersects(a, b: Pkgver_SemiRange) return Boolean;



    type Makepkg_Conf is record
        CARCH: Unbounded_String;
        CHOST: Unbounded_String;

        CPPFLAGS: Unbounded_String;
        CFLAGS: Unbounded_String;
        CXXFLAGS: Unbounded_String;
        LDFLAGS: Unbounded_String;
        RUSTFLAGS: Unbounded_String;
        MAKEFLAGS: Unbounded_String;
        DEBUG_CFLAGS: Unbounded_String;
        DEBUG_CXXFLAGS: Unbounded_String;
        DEBUG_RUSTFLAGS: Unbounded_String;
        DISTCC_HOSTS: Unbounded_String;

        STRIP_BINARIES: Unbounded_String;
        STRIP_SHARED: Unbounded_String;
        STRIP_STATIC: Unbounded_String;

        BUILDDIR: Unbounded_String;
        DBGSRCDIR: Unbounded_String;
        PKGDEST: Unbounded_String;
        SRCDEST: Unbounded_String;
        SRCPKGDEST: Unbounded_String;
        LOGDEST: Unbounded_String;

        PACKAGER: Unbounded_String;
        GPGKEY: Unbounded_String;
        PKGEXT: Unbounded_String;
        SRCEXT: Unbounded_String;

        DLAGENTS: String_Vectors.Vector;
        VCSCLIENTS: String_Vectors.Vector;
        BUILDENV: String_Vectors.Vector;
        OPTIONS: String_Vectors.Vector;
        INTEGRITY_CHECK: String_Vectors.Vector;
        MAN_DIRS: String_Vectors.Vector;
        DOC_DIRS: String_Vectors.Vector;
        PURGE_TARGETS: String_Vectors.Vector;

        COMPRESSGZ: String_Vectors.Vector;
        COMPRESSBZ2: String_Vectors.Vector;
        COMPRESSXZ: String_Vectors.Vector;
        COMPRESSZST: String_Vectors.Vector;
        COMPRESSLRZ: String_Vectors.Vector;
        COMPRESSLZO: String_Vectors.Vector;
        COMPRESSZ: String_Vectors.Vector;
        COMPRESSLZ4: String_Vectors.Vector;
        COMPRESSLZ: String_Vectors.Vector;
    end record;

    procedure Load_Data(data: String; conf: out Makepkg_Conf; overwrite: Boolean := True);
    procedure Load_Env(conf: out Makepkg_Conf; overwrite: Boolean := True);

    function Load_Data(data: String) return Makepkg_Conf;



    type PkgSrcinfo_Arch is record
        provides: String_Vectors.Vector;
        conflicts: String_Vectors.Vector;
        replaces: String_Vectors.Vector;
    end record;

    package PkgSrcinfo_Arch_Maps is new Ada.Containers.Hashed_Maps(
        Key_Type        => Unbounded_String,
        Element_Type    => PkgSrcinfo_Arch,
        Hash            => Hash,
        Equivalent_Keys => "=");
    use PkgSrcinfo_Arch_Maps;


    type PkgSrcinfo is record
        pkgdesc: Unbounded_String;
        url: Unbounded_String;
        install: Unbounded_String;
        changelog: Unbounded_String;

        license: String_Vectors.Vector;
        groups: String_Vectors.Vector;
        backup: String_Vectors.Vector;
        options: String_Vectors.Vector;

        arches: PkgSrcinfo_Arch_Maps.Map;
    end record;
    type PkgSrcinfo_Access is access all PkgSrcinfo;

    package PkgSrcinfo_Maps is new Ada.Containers.Hashed_Maps(
        Key_Type        => Unbounded_String,
        Element_Type    => PkgSrcinfo,
        Hash            => Hash,
        Equivalent_Keys => "=");
    use PkgSrcinfo_Maps;


    type Srcinfo_Arch is record
        source: String_Vectors.Vector;
        depends: String_Vectors.Vector;
        optdepends: String_Vectors.Vector;
        makedepends: String_Vectors.Vector;
        checkdepends: String_Vectors.Vector;

        cksums: String_Vectors.Vector;
        md5sums: String_Vectors.Vector;
        sha1sums: String_Vectors.Vector;
        sha224sums: String_Vectors.Vector;
        sha256sums: String_Vectors.Vector;
        sha384sums: String_Vectors.Vector;
        sha512sums: String_Vectors.Vector;
        b2sums: String_Vectors.Vector;

        provides: String_Vectors.Vector;
        conflicts: String_Vectors.Vector;
        replaces: String_Vectors.Vector;
    end record;

    package Srcinfo_Arch_Maps is new Ada.Containers.Hashed_Maps(
        Key_Type        => Unbounded_String,
        Element_Type    => Srcinfo_Arch,
        Hash            => Hash,
        Equivalent_Keys => "=");
    use Srcinfo_Arch_Maps;


    type Srcinfo is record
        pkgbase: Unbounded_String;
        pkgver: Unbounded_String;
        pkgrel: Natural := 0;
        epoch: Natural := 0;

        arch: String_Vectors.Vector;
        noextract: String_Vectors.Vector;
        validpgpkeys: String_Vectors.Vector;

        pkgdesc: Unbounded_String;
        url: Unbounded_String;
        install: Unbounded_String;
        changelog: Unbounded_String;

        license: String_Vectors.Vector;
        groups: String_Vectors.Vector;
        backup: String_Vectors.Vector;
        options: String_Vectors.Vector;

        arches: Srcinfo_Arch_Maps.Map;
        packages: PkgSrcinfo_Maps.Map;
    end record;
    type Srcinfo_Access is access all Srcinfo;

    procedure Parse_Srcinfo_KV(key: String; val: String; info: in out Srcinfo; pkginfo_cursor: in out PkgSrcinfo_Maps.Cursor);
    procedure Parse_Srcinfo_Line(line: String; info: in out Srcinfo; pkginfo_cursor: in out PkgSrcinfo_Maps.Cursor);
    function Parse_Srcinfo_Data(data: String) return Srcinfo;

    function Get_Version(info: Srcinfo) return String;
    function Get_Version(info: Srcinfo) return Unbounded_String;

    package Srcinfo_Vectors is new Ada.Containers.Vectors(
        Index_Type   => Positive,
        Element_Type => Srcinfo);
--    use Srcinfo_Vectors;
end Alpm;
