--with Utility;
--use  Utility;

with Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Text_IO;
use  Ada.Strings,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Text_IO;

with TOML;
use all type TOML.TOML_Value;


package body Alpm is
    function Vercmp(a, b: String) return Integer is
        a_cstr: chars_ptr := New_String(a);
        b_cstr: chars_ptr := New_String(b);
        result: constant Integer := Integer(Vercmp(a_cstr, b_cstr));
    begin
        Free(a_cstr);
        Free(b_cstr);
        return result;
    end Vercmp;

    function Vercmp(a, b: Unbounded_String) return Integer is
    begin
        return Vercmp(To_String(a), To_String(b));
    end Vercmp;



    function Value(s: String) return Pkgver_CmpOp is
    begin
        if s'Length = 0 then
            raise Constraint_Error;
        end if;

        case s(s'First) is
            when '=' =>
                return Eq;

            when '<' =>
                if s'Length >= 2 and then s(s'First + 1) = '=' then
                    return Le;
                else
                    return Lt;
                end if;

            when '>' =>
                if s'Length >= 2 and then s(s'First + 1) = '=' then
                    return Ge;
                else
                    return Gt;
                end if;

            when others => raise Constraint_Error;
        end case;
    end;


    function Intersects(a, b: Pkgver_SemiRange) return Boolean is
        cmpres: constant Integer := Vercmp(a.ver, b.ver);
    begin
        case a.op is
        when Eq =>
            case b.op is
            when Eq => return cmpres = 0;
            when Lt => return cmpres < 0;
            when Gt => return cmpres > 0;
            when Le => return cmpres <= 0;
            when Ge => return cmpres >= 0;
            end case;
        when Lt =>
            case b.op is
            when Eq => return cmpres > 0;
            when Lt => return True;
            when Gt => return cmpres > 0;
            when Le => return True;
            when Ge => return cmpres > 0;
            end case;
        when Gt =>
            case b.op is
            when Eq => return cmpres < 0;
            when Lt => return cmpres < 0;
            when Gt => return True;
            when Le => return cmpres < 0;
            when Ge => return True;
            end case;
        when Le =>
            case b.op is
            when Eq => return cmpres >= 0;
            when Lt => return True;
            when Gt => return cmpres > 0;
            when Le => return True;
            when Ge => return cmpres >= 0;
            end case;
        when Ge =>
            case b.op is
            when Eq => return cmpres <= 0;
            when Lt => return cmpres < 0;
            when Gt => return True;
            when Le => return cmpres <= 0;
            when Ge => return True;
            end case;
        end case;
    end Intersects;



    function Is_VCS(pkgname: String) return Boolean is
    begin
        return  Ends_With(pkgname, "-git")
        or else Ends_With(pkgname, "-svn")
        or else Ends_With(pkgname, "-bzr")
        or else Ends_With(pkgname, "-hg")
        or else Ends_With(pkgname, "-cvs")
        or else Ends_With(pkgname, "-nightly");
    end Is_VCS;

    function Is_VCS(pkgname: Unbounded_String) return Boolean is
    begin
        return Is_VCS(To_String(pkgname));
    end Is_VCS;


    function Get_Local_DBs(path: String) return String_Vectors.Vector is
        result: String_Vectors.Vector;
        section: Unbounded_String;

        procedure Process_File(path: String) is
            file: Ada.Text_IO.File_Type;
        begin
            Open(file, In_File, path);

            begin
                while not End_Of_File(file) loop
                    declare
                        line: constant String := Trim(Get_Line(file), Both);
                        i: Natural;
                    begin
                        if line'Length /= 0 and then line(line'First) /= '#' then
                            if line(line'First) = '[' then
                                if line'Length = 1 or else line(line'Last) /= ']' then
                                    raise Program_Error with path & " contains a section name that doesn't end with a ']'";
                                end if;
                                if line'Length = 2 then
                                    raise Program_Error with path & " contains an empty section name";
                                end if;
                                Set_Unbounded_String(section, line(line'First + 1 .. line'Last - 1));

                            else
                                i := Index(line, To_Set('='));
                                if i /= 0 then
                                    declare
                                        k: constant String := Trim(line(line'First .. i-1), Both);
                                        v: constant String := Trim(line(i+1 .. line'Last), Both);
                                    begin
                                        if k = "Include" then
                                            if v /= "/etc/pacman.d/mirrorlist" then
                                                Process_File(v);
                                            end if;
                                        elsif k = "Server" then
                                            if Starts_With (v, "file://") then
                                                result.Append(Fs.Full_Name(v(v'First + 7 .. v'Last) & '/' & To_String(section) & ".db"));
                                            end if;
                                        end if;
                                    end;
                                end if;
                            end if;
                        end if;
                    end;
                end loop;
            exception
                when others => Close(file); raise;
            end;

            Close(file);
        end;

    begin
        Process_File(path);
        return result;
    end Get_Local_DBs;



    procedure Srcinfo_Split_Source(src: String; filename, protocol, url: in out Unbounded_String) is
        i: Natural;
        j: Natural;
    begin
        Set_Unbounded_String(filename, "");
        Set_Unbounded_String(protocol, "");
        Set_Unbounded_String(url, "");

        i := Index(src, "::");
        if i = 0 then
            Set_Unbounded_String(url, src);
        else
            Set_Unbounded_String(filename, src(src'First .. i-1));
            Set_Unbounded_String(url, src(i+2 .. src'Last));
        end if;

        i := url.Index("://");
        if i = 0 then
            Set_Unbounded_String(protocol, "local");
        else
            j := Index(url.Slice(1, i-1), To_Set("+"));
            if j = 0 then
                Set_Unbounded_String(protocol, url.Slice(1, i-1));
            else
                Set_Unbounded_String(protocol, url.Slice(1, j-1));
                url.Delete(1, j);
            end if;
        end if;

        if filename.Length = 0 then
            if protocol = "local" then
                filename := url;
                filename.Trim(Null_Set, To_Set('/'));
                i := filename.Index(To_Set('/'), 1, Going => Backward);
                filename.Delete(1, i);
            else
                i := url.Index(To_Set('#'));
                if i = 0 then
                    i := url.Length + 1;
                end if;

                j := url.Index(To_Set('?'), i-1, Going => Backward);
                if j /= 0 then
                    i := j;
                end if;

                Set_Unbounded_String(filename, url.Slice(1, i-1));
                filename.Trim(Null_Set, To_Set('/'));
                i := filename.Index(To_Set('/'), 1, Going => Backward);
                filename.Delete(1, i);

                if protocol = "git" then
                    filename.Append(".git");
                end if;
            end if;
        end if;

        for i in 1 .. url.Length loop
            if url.Element(i) = ''' then
                url.Replace_Slice(i, i, "%27");
            end if;
        end loop;
    end Srcinfo_Split_Source;



    procedure Load_Data(data: String; conf: out Makepkg_Conf; overwrite: Boolean := True) is
        result: constant TOML.Read_Result := TOML.Load_String(data);

        procedure Load(key: String; var: out Unbounded_String) is
            value: constant TOML.TOML_Value := result.Value.Get_Or_Null(key);
        begin
            if value.Is_Present and then (overwrite or else var.Length = 0) then
                var := value.As_Unbounded_String;
            end if;
        end Load;

        procedure Load(key: String; var: out String_Vectors.Vector) is
            value: constant TOML.TOML_Value := result.Value.Get_Or_Null(key);
        begin
            if value.Is_Present and then value.Length /= 0 and then (overwrite or else var.Length = 0) then
                var.Reserve_Capacity(Count_Type(value.Length));
                for i in 1 .. value.Length loop
                    var.Append(value.Item(i).As_String);
                end loop;
            end if;
        end Load;

    begin
        if not result.Success then
            raise Program_Error with To_String(result.Message);
        end if;

        Load("CARCH", conf.CARCH);
        Load("CHOST", conf.CHOST);

        Load("CPPFLAGS",        conf.CPPFLAGS);
        Load("CFLAGS",          conf.CFLAGS);
        Load("CXXFLAGS",        conf.CXXFLAGS);
        Load("LDFLAGS",         conf.LDFLAGS);
        Load("RUSTFLAGS",       conf.RUSTFLAGS);
        Load("MAKEFLAGS",       conf.MAKEFLAGS);
        Load("DEBUG_CFLAGS",    conf.DEBUG_CFLAGS);
        Load("DEBUG_CXXFLAGS",  conf.DEBUG_CXXFLAGS);
        Load("DEBUG_RUSTFLAGS", conf.DEBUG_RUSTFLAGS);
        Load("DISTCC_HOSTS",    conf.DISTCC_HOSTS);

        Load("STRIP_BINARIES", conf.STRIP_BINARIES);
        Load("STRIP_SHARED",   conf.STRIP_SHARED);
        Load("STRIP_STATIC",   conf.STRIP_STATIC);

        Load("BUILDDIR",   conf.BUILDDIR);
        Load("DBGSRCDIR",  conf.DBGSRCDIR);
        Load("PKGDEST",    conf.PKGDEST);
        Load("SRCDEST",    conf.SRCDEST);
        Load("SRCPKGDEST", conf.SRCPKGDEST);
        Load("LOGDEST",    conf.LOGDEST);

        Load("PACKAGER", conf.PACKAGER);
        Load("GPGKEY",   conf.GPGKEY);
        Load("PKGEXT",   conf.PKGEXT);
        Load("SRCEXT",   conf.SRCEXT);

        Load("DLAGENTS",        conf.DLAGENTS);
        Load("VCSCLIENTS",      conf.VCSCLIENTS);
        Load("BUILDENV",        conf.BUILDENV);
        Load("OPTIONS",         conf.OPTIONS);
        Load("INTEGRITY_CHECK", conf.INTEGRITY_CHECK);
        Load("MAN_DIRS",        conf.MAN_DIRS);
        Load("DOC_DIRS",        conf.DOC_DIRS);
        Load("PURGE_TARGETS",   conf.PURGE_TARGETS);

        Load("COMPRESSGZ",  conf.COMPRESSGZ);
        Load("COMPRESSBZ2", conf.COMPRESSBZ2);
        Load("COMPRESSXZ",  conf.COMPRESSXZ);
        Load("COMPRESSZST", conf.COMPRESSZST);
        Load("COMPRESSLRZ", conf.COMPRESSLRZ);
        Load("COMPRESSLZO", conf.COMPRESSLZO);
        Load("COMPRESSZ",   conf.COMPRESSZ);
        Load("COMPRESSLZ4", conf.COMPRESSLZ4);
        Load("COMPRESSLZ",  conf.COMPRESSLZ);
    end Load_Data;


    procedure Load_Env(conf: out Makepkg_Conf; overwrite: Boolean := True) is
        procedure Load(key: String; var: out Unbounded_String) is
        begin
            if Env.Exists(key) and then (overwrite or else var.Length = 0) then
                Set_Unbounded_String(var, Env.Value(key));
            end if;
        end Load;

    begin
        Load("CARCH", conf.CARCH);
        Load("CHOST", conf.CHOST);

        Load("CPPFLAGS",        conf.CPPFLAGS);
        Load("CFLAGS",          conf.CFLAGS);
        Load("CXXFLAGS",        conf.CXXFLAGS);
        Load("LDFLAGS",         conf.LDFLAGS);
        Load("RUSTFLAGS",       conf.RUSTFLAGS);
        Load("MAKEFLAGS",       conf.MAKEFLAGS);
        Load("DEBUG_CFLAGS",    conf.DEBUG_CFLAGS);
        Load("DEBUG_CXXFLAGS",  conf.DEBUG_CXXFLAGS);
        Load("DEBUG_RUSTFLAGS", conf.DEBUG_RUSTFLAGS);
        Load("DISTCC_HOSTS",    conf.DISTCC_HOSTS);

        Load("STRIP_BINARIES", conf.STRIP_BINARIES);
        Load("STRIP_SHARED",   conf.STRIP_SHARED);
        Load("STRIP_STATIC",   conf.STRIP_STATIC);

        Load("BUILDDIR",   conf.BUILDDIR);
        Load("DBGSRCDIR",  conf.DBGSRCDIR);
        Load("PKGDEST",    conf.PKGDEST);
        Load("SRCDEST",    conf.SRCDEST);
        Load("SRCPKGDEST", conf.SRCPKGDEST);
        Load("LOGDEST",    conf.LOGDEST);

        Load("PACKAGER", conf.PACKAGER);
        Load("GPGKEY",   conf.GPGKEY);
        Load("PKGEXT",   conf.PKGEXT);
        Load("SRCEXT",   conf.SRCEXT);
    end Load_Env;


    function Load_Data(data: String) return Makepkg_Conf is
        conf: Makepkg_Conf;
    begin
        Load_Data(data, conf, True);
        return conf;
    end Load_Data;



    procedure Parse_Srcinfo_KV(key: String; val: String; info: in out Srcinfo; pkginfo_cursor: in out PkgSrcinfo_Maps.Cursor) is
        procedure Check_Global_Context is
        begin
            if Has_Element(pkginfo_cursor) then
                raise Key_Context_Error with key & " in " & To_String(PkgSrcinfo_Maps.Key(pkginfo_cursor));
            end if;
        end Check_Global_Context;

        procedure Check_NonEmpty_Value is
        begin
            if val'Length = 0 then
                raise Constraint_Error with key & " must not be empty";
            end if;
        end Check_NonEmpty_Value;


        procedure Raise_Repeated_Key_Error_If(cond: Boolean) is
        begin
            if cond then
                raise Repeated_Key_Error with key & " = " & val;
            end if;
        end Raise_Repeated_Key_Error_If;

        procedure Raise_Repeated_Value_Error_If(cond: Boolean) is
        begin
            if cond then
                raise Repeated_Value_Error with key & " = " & val;
            end if;
        end Raise_Repeated_Value_Error_If;


        function Get_Arch return String is
            i: constant Natural := Index(key, To_Set('_'));
        begin
            if i = 0 then
                return "";
            else
                return key(i+1 .. key'Last);
            end if;
        end Get_Arch;

        function Get_Arch return Unbounded_String is
        begin
            return To_Unbounded_String(Get_Arch);
        end Get_Arch;

        function Get_Archinfo return Srcinfo_Arch_Maps.Reference_Type is
            arch: constant Unbounded_String := Get_Arch;
            it: Srcinfo_Arch_Maps.Cursor := info.arches.Find(arch);
            dummy: Boolean;
        begin
            if not Has_Element(it) then
                info.arches.Insert(arch, it, dummy);
            end if;
            return info.arches.Reference(it);
        end Get_Archinfo;

        function Get_PkgArchinfo return PkgSrcinfo_Arch_Maps.Reference_Type is
            arch: constant Unbounded_String := Get_Arch;
            pkginfo: constant not null access PkgSrcinfo := info.packages.Reference(pkginfo_cursor).Element;
            it: PkgSrcinfo_Arch_Maps.Cursor := pkginfo.arches.Find(arch);
            dummy: Boolean;
        begin
            if not Has_Element(it) then
                pkginfo.arches.Insert(arch, it, dummy);
            end if;
            return pkginfo.arches.Reference(it);
        end Get_PkgArchinfo;


        type Existing_Handler is (Append, Error, Skip);

        procedure Append_Value_To(container: in out String_Vectors.Vector; onexist: Existing_Handler) is
        begin
            case onexist is
                when Append => null;
                when Error => Raise_Repeated_Value_Error_If(container.Contains(val));
                when Skip => if container.Contains(val) then return; end if;
            end case;

            container.Append(val);
        end Append_Value_To;

        procedure Initialize_Value(str: in out Unbounded_String) is
        begin
            Raise_Repeated_Key_Error_If(Length(str) /= 0);
            Set_Unbounded_String(str, val);
        end Initialize_Value;


    begin
        Check_NonEmpty_Value;

        if key = "pkgbase" then
            Check_Global_Context;
            Raise_Repeated_Key_Error_If(Length(info.pkgbase) /= 0);
            Set_Unbounded_String(info.pkgbase, val);

        else
            if not Has_Element(pkginfo_cursor) and then Length(info.pkgbase) = 0 then
                raise Key_Context_Error with "pkgbase section must be specified first";
            end if;

            if key = "pkgver" then
                Check_Global_Context;
                Initialize_Value(info.pkgver);

            elsif key = "pkgrel" then
                Check_Global_Context;
                Raise_Repeated_Key_Error_If(info.pkgrel /= 0);
                info.pkgrel := Positive'Value(val);

            elsif key = "epoch" then
                Check_Global_Context;
                Raise_Repeated_Key_Error_If(info.epoch /= 0);
                info.epoch := Positive'Value(val);

            elsif key = "arch" then
                Check_Global_Context;
                Append_Value_To(info.arch, Skip);

            elsif key = "noextract" then
                Check_Global_Context;
                Append_Value_To(info.noextract, Skip);

            elsif key = "validpgpkeys" then
                Check_Global_Context;
                Append_Value_To(info.validpgpkeys, Skip);


            elsif Starts_With(key, "source") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.source, Error);

            elsif Starts_With(key, "depends") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.depends, Skip);

            elsif Starts_With(key, "optdepends") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.optdepends, Skip);

            elsif Starts_With(key, "makedepends") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.makedepends, Skip);

            elsif Starts_With(key, "checkdepends") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.checkdepends, Skip);

            elsif Starts_With(key, "cksums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.cksums, Append);

            elsif Starts_With(key, "md5sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.md5sums, Append);

            elsif Starts_With(key, "sha1sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.sha1sums, Append);

            elsif Starts_With(key, "sha224sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.sha224sums, Append);

            elsif Starts_With(key, "sha256sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.sha256sums, Append);

            elsif Starts_With(key, "sha384sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.sha384sums, Append);

            elsif Starts_With(key, "sha512sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.sha512sums, Append);

            elsif Starts_With(key, "b2sums") then
                Check_Global_Context;
                Append_Value_To(Get_Archinfo.b2sums, Append);

            elsif key = "pkgname" then
                declare
                    cursor: PkgSrcinfo_Maps.Cursor;
                    inserted: Boolean;
                begin
                    Insert(info.packages, To_Unbounded_String(val), cursor, inserted);
                    Raise_Repeated_Key_Error_If(not inserted);
                    pkginfo_cursor := cursor;
                end;

            elsif key = "pkgdesc" then
                if Has_Element(pkginfo_cursor) then
                    Initialize_Value(Reference(info.packages, pkginfo_cursor).pkgdesc);
                else
                    Initialize_Value(info.pkgdesc);
                end if;

            elsif key = "url" then
                if Has_Element(pkginfo_cursor) then
                    Initialize_Value(Reference(info.packages, pkginfo_cursor).url);
                else
                    Initialize_Value(info.url);
                end if;

            elsif key = "install" then
                if Has_Element(pkginfo_cursor) then
                    Initialize_Value(Reference(info.packages, pkginfo_cursor).install);
                else
                    Initialize_Value(info.install);
                end if;

            elsif key = "changelog" then
                if Has_Element(pkginfo_cursor) then
                    Initialize_Value(Reference(info.packages, pkginfo_cursor).changelog);
                else
                    Initialize_Value(info.changelog);
                end if;

            elsif key = "license" then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Reference(info.packages, pkginfo_cursor).license, Skip);
                else
                    Append_Value_To(info.license, Skip);
                end if;

            elsif key = "groups" then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Reference(info.packages, pkginfo_cursor).groups, Skip);
                else
                    Append_Value_To(info.groups, Skip);
                end if;

            elsif key = "backup" then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Reference(info.packages, pkginfo_cursor).backup, Skip);
                else
                    Append_Value_To(info.backup, Skip);
                end if;

            elsif key = "options" then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Reference(info.packages, pkginfo_cursor).options, Skip);
                else
                    Append_Value_To(info.options, Skip);
                end if;


            elsif Starts_With(key, "provides") then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Get_PkgArchinfo.provides, Skip);
                else
                    Append_Value_To(Get_Archinfo.provides, Skip);
                end if;

            elsif Starts_With(key, "conflicts") then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Get_PkgArchinfo.conflicts, Skip);
                else
                    Append_Value_To(Get_Archinfo.conflicts, Skip);
                end if;

            elsif Starts_With(key, "replaces") then
                if Has_Element(pkginfo_cursor) then
                    Append_Value_To(Get_PkgArchinfo.replaces, Skip);
                else
                    Append_Value_To(Get_Archinfo.replaces, Skip);
                end if;

            else
                raise Unknown_Key_Error with key;
            end if;
        end if;
    end;


    procedure Parse_Srcinfo_Line(line: String; info: in out Srcinfo; pkginfo_cursor: in out PkgSrcinfo_Maps.Cursor) is
        kbeg: Positive := line'First;
        kend: Positive;
        vbeg: Positive;
        vend: Positive;
        ieq: Positive;
    begin
        while kbeg <= line'Last and then line(kbeg) in ' ' | ASCII.HT loop
            kbeg := kbeg + 1;
        end loop;

        if kbeg > line'Last or else line(kbeg) = '#' then
            return;

        else
            kend := kbeg;
            while kend <= line'Last and then line(kend) not in ' ' | ASCII.HT loop
                kend := kend + 1;
            end loop;

            ieq := kend;
            while ieq <= line'Last and then line(ieq) in ' ' | ASCII.HT loop
                ieq := ieq + 1;
            end loop;
            if ieq > line'Last or else line(ieq) /= '=' then
                raise Not_KV_Error with ".SRCINFO line must be a key/value pair";
            end if;

            vbeg := ieq + 1;
            while vbeg <= line'Last and then line(vbeg) in ' ' | ASCII.HT loop
                vbeg := vbeg + 1;
            end loop;

            vend := line'Last + 1;
            while vend > vbeg and then line(vend - 1) in ' ' | ASCII.HT loop
                vend := vend - 1;
            end loop;

            Parse_Srcinfo_KV(line(kbeg..kend-1), line(vbeg..vend-1), info, pkginfo_cursor);
        end if;
    end;


    function Parse_Srcinfo_Data(data: String) return Srcinfo is
        info: Srcinfo;
        pkginfo_cursor: PkgSrcinfo_Maps.Cursor;
        linebeg: Positive := data'First;
        lineend: Natural := data'First - 1;
    begin
        while Next_Line(data, linebeg, lineend) loop
            Parse_Srcinfo_Line(data(linebeg .. lineend - 1), info, pkginfo_cursor);
        end loop;
        return info;
    end Parse_Srcinfo_Data;



    function Get_Version(info: Srcinfo) return Unbounded_String is
    begin
        if info.epoch = 0 then
            return info.pkgver & '-' & Trim(info.pkgrel'Image, Left);
        else
            return info.epoch'Image & ':' & info.pkgver & '-' & Trim(info.pkgrel'Image, Left);
        end if;
    end Get_Version;

    function Get_Version(info: Srcinfo) return String is
    begin
        return To_String(Get_Version(info));
    end Get_Version;
end Alpm;
