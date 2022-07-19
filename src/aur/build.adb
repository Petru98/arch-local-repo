with Utility,
     Cfg;
use  Utility.String_Vectors,
     Cfg;

with Alpm;
use  Alpm,
     Alpm.Srcinfo_Vectors,
     Alpm.Srcinfo_Arch_Maps,
     Alpm.PkgSrcinfo_Maps,
     Alpm.PkgSrcinfo_Arch_Maps;

with Ada.Strings.Unbounded,
     Ada.Strings.Unbounded.Hash,
     Ada.Strings.Fixed,
     Ada.Strings.Hash,
     Ada.Strings.Maps,
     Ada.Containers.Vectors,
     Ada.Containers.Hashed_Sets,
     Ada.Containers.Indefinite_Hashed_Maps,
     Ada.Text_IO,
     Ada.Exceptions;
use  Ada.Strings.Unbounded,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Strings,
     Ada.Containers,
     Ada.Text_IO,
     Ada.Exceptions;

with System.Multiprocessors;
use  System.Multiprocessors;



function Build(
    pkgbases: in out String_Vectors.Vector;
    devel: OptBool := None
) return Exit_Status
is
    type Dep_Kind is (Pkg, Prvd);
    type Dep_Info(kind: Dep_Kind := Pkg) is record
        info: Srcinfo_Access;
        case kind is
            when Pkg =>
                pkginfo: PkgSrcinfo_Access;
                db: Unbounded_String;
            when Prvd =>
                semirange: Pkgver_SemiRange;
        end case;
    end record;

    package Dep_Info_Vectors is new Ada.Containers.Vectors(Positive, Dep_Info);
    use Dep_Info_Vectors;
    package Dep_Info_Maps is new Ada.Containers.Indefinite_Hashed_Maps(String, Dep_Info_Vectors.Vector, Hash, "=");
    use Dep_Info_Maps;

    function Get_SemiRange(depinfo: Dep_Info) return Pkgver_SemiRange is
    begin
        case depinfo.kind is
            when Pkg => return (Eq, depinfo.info.pkgver);
            when Prvd => return depinfo.semirange;
        end case;
    end;


    arches: constant array(1..2) of Unbounded_String := [Null_Unbounded_String, makepkg.CARCH];
    localdbs: constant String_Vectors.Vector := Get_Local_DBs("/etc/pacman.conf");
    srcinfos: Srcinfo_Vectors.Vector := Empty(pkgbases.Length);
    deps: Dep_Info_Maps.Map := Empty(pkgbases.Length);


begin
    if Length(localdbs) = 0 then
        raise Program_Error with "no local pacman databases found";
    end if;

    if makepkg.PKGDEST.Length = 0 then
        Set_Unbounded_String(makepkg.PKGDEST, Fs.Containing_Directory(localdbs.First_Element));
        Env.Set("PKGDEST", To_String(makepkg.PKGDEST));
    end if;

    Filter_Packages(pkgbases, devel);


Get_Srcinfos:
    declare
        errcount: Natural := 0;
        protected Errors is
            procedure Increment;
        end;

        protected body Errors is
            procedure Increment is
            begin
                errcount := errcount + 1;
            end;
        end;


        protected Package_Queue is
            procedure Pop(s: out Unbounded_String);
        private
            index: Natural := pkgbases.First_Index;
        end;

        protected body Package_Queue is
            procedure Pop(s: out Unbounded_String) is
            begin
                if index > pkgbases.Last_Index then
                    Set_Unbounded_String(s, "");
                else
                    Set_Unbounded_String(s, pkgbases.Element(index));
                    index := index + 1;
                end if;
            end Pop;
        end;


        protected Srcinfo_List is
            procedure Push(info: Srcinfo);
        end;

        protected body Srcinfo_List is
            procedure Push(info: Srcinfo) is
            begin
                srcinfos.Append(info);
            end Push;
        end;


        task type T is
            entry Join;
        end T;

        task body T is
            pkgbase: Unbounded_String;

        begin
            begin
                loop
                    Package_Queue.Pop(pkgbase);
                    exit when Length(pkgbase) = 0;

                    if Is_VCS(pkgbase) then
                        Cmd_Exec(
                            args => ["makepkg", "--nodeps", "--skipinteg", "--noprepare", "--nobuild"],
                            env  => ["BUILDDIR" => tmpdir & "/makepkg"],
                            cwd  => repodir & '/' & To_String(pkgbase));
                        Fs.Delete_Tree(To_String(tmpdir & "/makepkg/" & pkgbase));
                    end if;

                    Srcinfo_List.Push(Parse_Srcinfo_Data(Read_Srcinfo(To_String(pkgbase), updatecache => True)));
                end loop;

            exception
                when e : others =>
                    Errors.Increment;
                    Put_Line(Exception_Information(e));
            end;

            select
                accept Join;
            or
                terminate;
            end select;
        end T;
        tasks: array(1..Number_Of_CPUs) of T;

    begin
        for t of tasks loop
            t.Join;
        end loop;

        if errcount /= 0 then
            return Failure;
        end if;
    end Get_Srcinfos;



Map_Packages_To_PkgInfo:
    declare
        procedure Add_Dep_Info(name: String; depinfo: Dep_Info) is
            it: Dep_Info_Maps.Cursor;
            inserted: Boolean;
        begin
            deps.Insert(name, Dep_Info_Vectors.Empty_Vector, it, inserted);
            deps.Reference(it).Append(depinfo);
        end Add_Dep_Info;

        procedure Add_Provides(provides: String_Vectors.Vector; info: Srcinfo_Access) is
        begin
            for x of provides loop
                declare
                    first: constant Natural := Ada.Strings.Fixed.Index(x, To_Set("=<>"));
                    last: constant Natural := (if first /= 0 and then x(first+1) = '=' then first+1 else first);
                    name: constant String := (if first = 0 then x else x(x'First..first-1));
                    ver: constant String := (if first = 0 then To_String(info.pkgver) else x(first..x'Last));
                    op: constant Pkgver_CmpOp := (if first = 0 then Eq else Value(x(first..last)));
                begin
                    Add_Dep_Info(name, Dep_Info'(info => info, kind => Prvd, semirange => (op, To_Unbounded_String(ver))));
                end;
            end loop;
        end Add_Provides;

    begin
        for info of srcinfos loop
            for arch of arches loop
                declare
                    it: constant Srcinfo_Arch_Maps.Cursor := info.arches.Find(arch);
                begin
                    if Has_Element(it) then
                        Add_Provides(info.arches.Reference(it).provides, info'Unchecked_Access);
                    end if;
                end;
            end loop;

            for it in info.packages.Iterate loop
                declare
                    pkgname: constant String := To_String(Key(it));
                    pkginfo: constant not null PkgSrcinfo_Access := info.packages.Reference(it).Element;
                begin
                    Add_Dep_Info(pkgname, Dep_Info'(info => info'Unchecked_Access, kind => Pkg, pkginfo => pkginfo, db => Null_Unbounded_String));
                    for arch of arches loop
                        declare
                            it: constant PkgSrcinfo_Arch_Maps.Cursor := pkginfo.arches.Find(arch);
                        begin
                            if Has_Element(it) then
                                Add_Provides(pkginfo.arches.Reference(it).provides, info'Unchecked_Access);
                            end if;
                        end;
                    end loop;
                end;
            end loop;
        end loop;
    end Map_Packages_To_PkgInfo;


Filter_Out_UpToDate_Packages:
    for dbpath of localdbs loop
        declare
            data: constant String := Cmd_Exec(["tar", "-t", "-f", dbpath]);
            linebeg: Positive := data'First;
            lineend: Natural := data'First - 1;

        begin
            while Next_Line(data, linebeg, lineend) loop
                if linebeg + 2 <= lineend and then data(lineend - 1) = '/' then
                    declare
                        line:               constant String      := data(linebeg .. lineend - 2);
                        pkgrel_dash_index:  constant Positive    := Index(line, To_Set('-'), line'Last, Inside, Backward);
                        version_dash_index: constant Positive    := Index(line, To_Set('-'), pkgrel_dash_index - 1, Inside, Backward);
                        pkgname:            constant String      := line(line'First .. version_dash_index - 1);
                        version:            constant String      := line(version_dash_index + 1 .. line'Last);
                        it:                 Dep_Info_Maps.Cursor := deps.Find(pkgname);

                    begin
                        if Has_Element(it) then
                            declare
                                depvec: constant not null access Dep_Info_Vectors.Vector := deps.Reference(it).Element;
                                i: Natural := depvec.First_Index;
                            begin

                                while i <= depvec.Last_Index loop
                                    declare
                                        dep: constant not null access Dep_Info := depvec.Constant_Reference(i).Element;
                                    begin

                                        if dep.kind = Pkg then
                                            if Vercmp(version, Get_Version(dep.info.all)) < 0 then
                                                if Length(dep.db) = 0 then
                                                    Set_Unbounded_String(dep.db, dbpath);
                                                end if;
                                                exit;
                                            else
                                                Put_Line("skipping " & pkgname & ": up-to-date");
                                                depvec.Swap(i, depvec.Last_Index);
                                                depvec.Delete_Last;
                                                if Length(depvec.all) = 0 then
                                                    deps.Delete(it);
                                                    exit;
                                                end if;
                                            end if;
                                        end if;
                                    end;
                                    i := i + 1;
                                end loop;
                            end;
                        end if;
                    end;
                end if;
            end loop;
        end;
    end loop Filter_Out_UpToDate_Packages;



Filter_Out_UpToDate_Srcinfos:
    declare
        i: Natural := srcinfos.First_Index;
        uptodate: Boolean;
    begin
        while i <= srcinfos.Last_Index loop
            uptodate := True;
            for it in srcinfos.Reference(i).packages.Iterate loop
                if deps.Contains(To_String(Key(it))) then
                    uptodate := False;
                    exit;
                end if;
            end loop;

            if uptodate then
                srcinfos.Swap(i, srcinfos.Last_Index);
                srcinfos.Delete_Last;
            else
                i := i + 1;
            end if;
        end loop;
    end Filter_Out_UpToDate_Srcinfos;



Makedep_Sort:
    declare
        function Hash(a: not null Srcinfo_Access) return Ada.Containers.Hash_Type is (Hash(a.pkgbase));

        package Srcinfo_Access_Vectors is new Ada.Containers.Vectors(Positive, Srcinfo_Access);
        use Srcinfo_Access_Vectors;

        package Srcinfo_Access_Sets is new Ada.Containers.Hashed_Sets(Srcinfo_Access, Hash, "=");
        use Srcinfo_Access_Sets;

        result: Srcinfo_Vectors.Vector := Empty(srcinfos.Length);
        sorted_srcinfos: Srcinfo_Access_Vectors.Vector := Empty(srcinfos.Length);
        visited: Srcinfo_Access_Sets.Set := Empty(srcinfos.Length);


        procedure Visit(info: Srcinfo_Access)
            with Pre => not visited.Contains(info);


        procedure Process_Depends(depends: String_Vectors.Vector) is
        begin
            for x of depends loop
                declare
                    first: constant Natural := Ada.Strings.Fixed.Index(x, To_Set("=<>"));
                    last: constant Natural := (if first /= 0 and then x(first+1) = '=' then first+1 else first);
                    name: constant String := (if first = 0 then x else x(x'First..first-1));
                    ver: constant String := (if first = 0 then "" else x(first..x'Last));
                    op: constant Pkgver_CmpOp := (if first = 0 then Eq else Value(x(first..last)));
                    semirange: constant Pkgver_SemiRange := (op, To_Unbounded_String(ver));
                    it: constant Dep_Info_Maps.Cursor := deps.Find(name);
                begin
                    if Has_Element(it) then
                        if ver'Length /= 0 then
                            declare
                                depinfos: constant not null access Dep_Info_Vectors.Vector := deps.Reference(it).Element;
                                i: Natural := depinfos.First_Index;
                            begin
                                while i <= depinfos.Last_Index loop
                                    if not Intersects(semirange, Get_SemiRange(depinfos.Constant_Reference(i))) then
                                        depinfos.Swap(i, depinfos.Last_Index);
                                        depinfos.Delete_Last;
                                    else
                                        i := i + 1;
                                    end if;
                                end loop;
                            end;
                        end if;

                        for depinfo of deps.Constant_Reference(it) loop  -- TODO: if at least one is unvisited then visit it; if all are already visited then we have a cycle
                            if not visited.Contains(depinfo.info) then
                                Visit(depinfo.info);
                            end if;
                        end loop;
                    end if;
                end;
            end loop;
        end Process_Depends;


        procedure Visit(info: Srcinfo_Access) is
        begin
            visited.Insert(info);

            for arch of arches loop
                declare
                    it: constant Srcinfo_Arch_Maps.Cursor := info.arches.Find(arch);
                begin
                    if Has_Element(it) then
                        Process_Depends(info.arches.Constant_Reference(it).depends);
                        Process_Depends(info.arches.Constant_Reference(it).makedepends);
                        Process_Depends(info.arches.Constant_Reference(it).checkdepends);
                    end if;
                end;
            end loop;

            sorted_srcinfos.Append(info);
        end Visit;


    begin
        for it in srcinfos.Iterate loop
            if not visited.Contains(srcinfos.Reference(it).Element) then
                Visit(srcinfos.Reference(it).Element);
            end if;
        end loop;

        for x of sorted_srcinfos loop
            result.Append(x.all);
        end loop;
        srcinfos.Move(result);
    end Makedep_Sort;



Build:
    for info of srcinfos loop
        Cmd_Exec(["makepkg", "-srcf"], cwd => repodir & '/' & To_String(info.pkgbase));

        declare
            version: constant String := Get_Version(info);
            arch: constant String := (if info.arch.First_Element = "any" then "any" else To_String(makepkg.CARCH));

        begin
            for it in info.packages.Iterate loop
                declare
                    pkgname: constant String := To_String(Key(it));
                    archivename: constant String := pkgname & '-' & version & '-' & arch & To_String(makepkg.PKGEXT);
                    archivepath: constant String := To_String(makepkg.PKGDEST) & '/' & archivename;
                    db: Unbounded_String := Null_Unbounded_String;
                begin
                    for dep of deps.Constant_Reference(pkgname) loop
                        if dep.kind = Pkg and then dep.info = info'Unchecked_Access then
                            db := dep.db;
                            exit;
                        end if;
                    end loop;

                    if db.Length = 0 then
                        Set_Unbounded_String(db, localdbs.First_Element);
                    end if;

                    Cmd_Exec(["repo-add", "-R", To_String(db), archivepath]);
                end;
            end loop;
        end;

        Put_Line("################################################################################");
    end loop Build;


    return Success;
end Build;
