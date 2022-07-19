with Utility,
     Cfg;
use  Utility.String_Vectors,
     Cfg;

with Alpm;
use  Alpm,
     Alpm.Srcinfo_Arch_Maps;

with Ada.Strings.Unbounded,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Strings.Equal_Case_Insensitive,
     Ada.Characters.Handling,
     Ada.Containers.Vectors,
     Ada.Text_IO,
     Ada.Exceptions;
use  Ada.Strings.Unbounded,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Strings,
     Ada.Characters.Handling,
     Ada.Containers,
     Ada.Text_IO,
     Ada.Exceptions;

with System.Multiprocessors;
use  System.Multiprocessors;



function Fix(
    pkgbases: in out String_Vectors.Vector
) return Exit_Status
is
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


    task type T is
        entry Join;
    end T;

    task body T is
        pkgbase: Unbounded_String;
        info: Srcinfo;

    begin
        begin
            loop
                Package_Queue.Pop(pkgbase);
                exit when Length(pkgbase) = 0;
                info := Parse_Srcinfo_Data(Read_Srcinfo(To_String(pkgbase), updatecache => True));

            Fix_Checksums:
                declare
                    type String_Pair is record
                        older, newer: Unbounded_String;
                    end record;

                    package String_Pair_Vectors is new Ada.Containers.Vectors(Positive, String_Pair);
                    use String_Pair_Vectors;

                    replacements: String_Pair_Vectors.Vector;


                    procedure Process_Sources(sources: String_Vectors.Vector; checksums: String_Vectors.Vector; algo: String)
                         with Pre => algo'Length /= 0
                            and then (checksums.Length = 0 or else checksums.Length = sources.Length)
                    is
                        filename: Unbounded_String;
                        protocol: Unbounded_String;
                        url: Unbounded_String;
                        catcmd: Unbounded_String;

                    begin
                        for offset in 0 .. checksums.Length - 1 loop
                            declare
                                i: constant String_Vectors.Extended_Index := sources.First_Index + String_Vectors.Extended_Index(offset);
                                j: constant String_Vectors.Extended_Index := checksums.First_Index + String_Vectors.Extended_Index(offset);
                            begin

                                if To_Lower(checksums(j)) /= "skip" then
                                    Srcinfo_Split_Source(sources(i), filename, protocol, url);
                                    Set_Unbounded_String(catcmd, "");


                                    if protocol = "local" then
                                        Set_Unbounded_String(catcmd, "cat '" & repodir & '/' & To_String(pkgbase) & '/' & To_String(url) & "'");
                                    else
                                        declare
                                            output: constant String := Trim(Cmd_Exec(["curl", "-Ls", "-o", "/dev/null", "-I", "-w", "%{http_code}", To_String(url)]), Both);
                                            status: constant Integer := Integer'Value(output);
                                        begin
                                            if status >= 300 then
                                                raise Program_Error with To_String(url) & " returned status code " & output;
                                            end if;
                                            Set_Unbounded_String(catcmd, "curl -Ls '" & To_String(url) & "'");
                                        end;
                                    end if;


                                    declare
                                        output: constant String := Trim(Cmd_Exec(["sh", "-c", To_String(catcmd) & " | " & algo & "sum -b"]), Both);
                                        newchecksum: constant String := To_Lower(output(1 .. Index(output, To_Set(' ')) - 1));
                                    begin
                                        if not Equal_Case_Insensitive(checksums(j), newchecksum) then
                                            replacements.Append(String_Pair'(
                                                older => To_Unbounded_String(checksums(j)),
                                                newer => To_Unbounded_String(newchecksum))
                                            );
                                        end if;
                                    end;
                                end if;
                            end;
                        end loop;
                    end Process_Sources;

                begin
                    for it in info.arches.Iterate loop
                        declare
                            archinfo: constant not null access Srcinfo_Arch := info.arches.Constant_Reference(it).Element;
                        begin
                            Process_Sources(archinfo.source, archinfo.md5sums, "md5");
                            Process_Sources(archinfo.source, archinfo.sha1sums, "sha1");
                            Process_Sources(archinfo.source, archinfo.sha224sums, "sha224");
                            Process_Sources(archinfo.source, archinfo.sha256sums, "sha256");
                            Process_Sources(archinfo.source, archinfo.sha384sums, "sha384");
                            Process_Sources(archinfo.source, archinfo.sha512sums, "sha512");
                            Process_Sources(archinfo.source, archinfo.b2sums, "b2");
                        end;
                    end loop;

                    if replacements.Length /= 0 then
                        declare
                            function ">" (Left, Right: String_Pair) return Boolean is (Left.older.Length > Right.older.Length);
                            package String_Pair_Sorting is new String_Pair_Vectors.Generic_Sorting(">");

                            pkgbuild_path: constant String := repodir & '/' & To_String(pkgbase) & "/PKGBUILD";
                            data: Unbounded_String := To_Unbounded_String(Read_File(pkgbuild_path));
                            i: Positive;

                        begin
                            -- FIXME: Unlikely. This requires more complex logic when editing the PKGBUILD file. Returning an error should be good enough for now.
                            for pair of replacements loop
                                if data.Count(To_String(pair.older)) >= 2 then
                                    raise Program_Error with To_String(pair.older) & " appears more than once in " & To_String(pkgbase) & "/PKGBUILD";
                                end if;
                            end loop;

                            String_Pair_Sorting.Sort(replacements);
                            for pair of replacements loop
                                i := data.Index(To_String(pair.older));
                                data.Replace_Slice(i, i + pair.older.Length - 1, To_String(pair.newer));
                            end loop;

                            Write_File(pkgbuild_path, To_String(data));
                        end;
                    end if;
                end Fix_Checksums;
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

    outdated_check: constant Boolean := pkgbases.Length = 0;

begin
    Filter_Packages(pkgbases, True);

    if outdated_check then
        declare
            i: Natural := pkgbases.First_Index;
        begin
            while i <= pkgbases.Last_Index loop
                if not Is_Srcinfo_Outdated(pkgbases.Element(i)) then
                    pkgbases.Swap(i, pkgbases.Last_Index);
                    pkgbases.Delete_Last;
                else
                    i := i + 1;
                end if;
            end loop;
        end;
    end if;

    declare
        tasks: array(1..Number_Of_CPUs) of T;
    begin
        for t of tasks loop
            t.Join;
        end loop;

        if errcount /= 0 then
            return Failure;
        end if;
    end;

    return Success;
end Fix;
