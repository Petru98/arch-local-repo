with Ada.Text_IO;
use  Ada.Text_IO;


package body Cfg is
    use all type Fs.File_Kind;


    procedure Filter_Packages(packages: in out String_Vectors.Vector; devel: OptBool := None) is
    begin
        if packages.Is_Empty then
            declare
               search: Fs.Search_Type;
               direntry: Fs.Directory_Entry_Type;
            begin
                Fs.Start_Search(search, repodir, "");
                while Fs.More_Entries(search) loop
                    Fs.Get_Next_Entry(search, direntry);

                    if Fs.Kind(direntry) = Fs.Directory then
                        declare
                            pkgbase: constant String := Fs.Simple_Name(direntry.Simple_Name);
                        begin
                            if pkgbase(pkgbase'First) /= '.' then
                                if not Fs.Exists(direntry.Full_Name & "/PKGBUILD") then
                                    Put_Line("error: " & pkgbase & "/PKGBUILD does not exist");
                                elsif devel /= True and then Is_VCS(pkgbase) then
                                    Put_Line("info: skipping vcs package " & pkgbase);
                                else
                                    packages.Append(pkgbase);
                                end if;
                            end if;
                        end;
                    end if;
                end loop;
                Fs.End_Search(search);
            end;

        else
            declare
                i: Natural := packages.First_Index;
            begin
                while i <= packages.Last_Index loop
                    if not Fs.Exists(repodir & '/' & packages(i) & "/PKGBUILD") then
                        raise Program_Error with packages(i) & "/PKGBUILD does not exist";
                    end if;

                    if devel = False and then Is_VCS(packages(i)) then
                        Put_Line("info: skipping vcs package " & packages(i));
                        packages.Swap(i, packages.Last_Index);
                        packages.Delete_Last;
                    else
                        i := i + 1;
                    end if;
                end loop;
            end;
        end if;
    end Filter_Packages;



    function Is_Srcinfo_Outdated(pkgbase: String) return Boolean is
        path: constant String := repodir & '/' & pkgbase;
    begin
        return Cmp_ModTime(path & "/.SRCINFO", path & "/PKGBUILD") < 0;
    end Is_Srcinfo_Outdated;

    function Generate_Srcinfo(pkgbase: String) return String is
    begin
        return Cmd_Exec(["makepkg", "--printsrcinfo"], cwd => repodir & '/' & pkgbase);
    end Generate_Srcinfo;


    procedure Update_Srcinfo(pkgbase: String; contents: String) is
    begin
        Write_File(repodir & '/' & pkgbase & "/.SRCINFO", contents);
    end Update_Srcinfo;

    function Update_Srcinfo(pkgbase: String) return String is
        contents: constant String := Generate_Srcinfo(pkgbase);
    begin
        Update_Srcinfo(pkgbase, contents);
        return contents;
    end Update_Srcinfo;


    function Read_Srcinfo(pkgbase: String; updatecache: Boolean) return String is
    begin
        if Is_Srcinfo_Outdated(pkgbase) then
            if updatecache then
                return Update_Srcinfo(pkgbase);
            else
                return Generate_Srcinfo(pkgbase);
            end if;
        else
            return Read_File(repodir & '/' & pkgbase & "/.SRCINFO");
        end if;
    end Read_Srcinfo;


begin
    Load_Env(makepkg);
    if not Env.Exists("MAKEPKG_CONF") then
        Env.Set("MAKEPKG_CONF", makepkg_conf_path);
    end if;
end Cfg;
