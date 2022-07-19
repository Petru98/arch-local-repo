with Utility,
     Alpm,
     Cfg;
use  Utility.String_Vectors,
     Alpm,
     Cfg;

with Ada.Strings.Unbounded,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Text_IO,
     Ada.Exceptions;
use  Ada.Strings.Unbounded,
     Ada.Strings.Fixed,
     Ada.Strings.Maps,
     Ada.Strings,
     Ada.Text_IO,
     Ada.Exceptions;

with System.Multiprocessors;
use  System.Multiprocessors;



function Ood(
    pkgbases: in out String_Vectors.Vector;
    devel: OptBool := None
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

    begin
        loop
            begin
                Package_Queue.Pop(pkgbase);
                exit when Length(pkgbase) = 0;
                Put_Line(To_String(pkgbase));

                declare
                    cmd_path: constant String := repodir & '/' & To_String(pkgbase) & "/LATESTVER";

                begin
                    if not Fs.Exists(cmd_path) then
                        if not Is_VCS(cmd_path) then
                            Put_Line("warning: " & cmd_path & " does not exist");
                        end if;

                    else
                        declare
                            info: constant Srcinfo := Parse_Srcinfo_Data(Read_Srcinfo(To_String(pkgbase), updatecache => True));
                            current_version: constant String := To_String(info.pkgver) & '-' & Trim(info.pkgrel'Image, Left);
                            identation: constant String := info.pkgbase.Length * ' ';
                            newer_count: Natural := 0;
                            msg: Unbounded_String := info.pkgbase & ' ' & current_version & ASCII.LF;

                            output: constant String := Trim(Cmd_Exec([cmd_path], cwd => rootdir), Both);
                            linebeg: Positive := 1;
                            lineend: Natural := 0;
                        begin
                            while Next_Line(output, linebeg, lineend) loop
                                declare
                                    line: constant String := Trim(output(linebeg .. lineend - 1), Both);
                                    i: constant Natural := Natural'Max(Index(line, To_Set(':')) + 1, line'First);
                                    version: constant String := line(i .. line'Last);
                                begin
                                    if line'Length /= 0 then
                                        if version'Length = 0 then
                                            Put_Line("error: " & cmd_path & " printed an invalid line: " & line);
                                        elsif Vercmp(version, current_version) > 0 then
                                            newer_count := newer_count + 1;
                                            msg.Append(identation & ' ' & version & ASCII.LF);
                                        end if;
                                    end if;
                                end;
                            end loop;

                            if newer_count > 0 then
                                Put_Line(To_String(msg));
                            end if;
                        end;
                    end if;
                end;

            exception
                when e : others =>
                    Errors.Increment;
                    Put_Line(Exception_Information(e));
            end;
        end loop;

        select
            accept Join;
        or
            terminate;
        end select;
    end T;


begin
    Filter_Packages(pkgbases, devel);

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
end Ood;
