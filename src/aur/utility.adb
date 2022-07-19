with Ada.Strings.Fixed,
     Ada.Direct_IO,
     Ada.Text_IO,
     Ada.Streams,
     Ada.Calendar,
     Ada.Unchecked_Conversion;
use  Ada.Strings.Fixed,
     Ada.Text_IO,
     Ada.Calendar;

with Util.Streams,
     Util.Processes;


package body Utility is
    function Cmp(x, y: Time) return Integer is
    begin
        if x < y then
            return -1;
        elsif x > y then
            return 1;
        else
            return 0;
        end if;
    end Cmp;



    function Starts_With(str, prefix: String) return Boolean is
    begin
        return prefix'Length <= str'Length and then str(str'First .. str'First + prefix'Length - 1) = prefix;
    end Starts_With;

    function Ends_With(str, suffix: String) return Boolean is
    begin
        return suffix'Length <= str'Length and then str(str'Last - suffix'Length + 1 .. str'Last) = suffix;
    end Ends_With;

    function Starts_With(str, prefix: Unbounded_String) return Boolean is
    begin
        return Starts_With(To_String(str), To_String(prefix));
    end Starts_With;

    function Ends_With(str, suffix: Unbounded_String) return Boolean is
    begin
        return Ends_With(To_String(str), To_String(suffix));
    end Ends_With;


    function Next_Line(str: String; linebeg: in out Positive; lineend: in out Natural) return Boolean is
    begin
        if lineend > str'Last then
            return False;
        end if;

        linebeg := lineend + 1;
        lineend := linebeg;
        while lineend <= str'Last and then str(lineend) /= ASCII.LF loop
            lineend := lineend + 1;
        end loop;

        return True;
    end Next_Line;


    function Cmp_ModTime(path1, path2: String) return Integer is
        t1: Time;
        t2: Time;
        t1set: Boolean := False;
        t2set: Boolean := False;
    begin
        begin
            t1 := Fs.Modification_Time(path1);
            t1set := True;
        exception
            when Name_Error => null;
        end;

        begin
            t2 := Fs.Modification_Time(path2);
            t2set := True;
        exception
            when Name_Error => null;
        end;

        if t1set then
            if t2set then
                return Cmp(t1, t2);
            else
                return 1;
            end if;
        else
            if t2set then
                return -1;
            else
                return 0;
            end if;
        end if;
    end Cmp_ModTime;


    function Read_File(path: String) return String is
        size: constant Natural := Natural(Ada.Directories.Size(path));

        subtype File_String is String (1 .. size);
        package File_String_IO is new Ada.Direct_IO(File_String);

        file: File_String_IO.File_Type;
        contents: File_String;
    begin
        File_String_IO.Open(file, File_String_IO.In_File, path);
        File_String_IO.Read(file, contents);
        File_String_IO.Close(file);
        return contents;
    end Read_File;

    procedure Write_File(path: String; contents: String) is
        file: Ada.Text_IO.File_Type;
    begin
        begin
            Open(file, Ada.Text_IO.Out_File, path);
        exception
            when Ada.Text_IO.Name_Error => Create(file, Ada.Text_IO.Out_File, path);
        end;

        Ada.Text_IO.Put(file, contents);
        Ada.Text_IO.Close(file);
    end Write_File;



    procedure Cmd_Exec(args: String_Vectors.Vector; env: String_Maps.Map := Empty_Map; cwd: String := "") is
        use all type Util.Processes.Process;
        proc: Util.Processes.Process;

    begin
        if cwd'Length /= 0 then
            Set_Working_Directory(proc, cwd);
        end if;
        for it in env.Iterate loop
            Set_Environment(proc, Key(it), Element(it));
        end loop;

        Util.Processes.Spawn(proc, args);
        Wait(proc);

        if Get_Exit_Status(proc) /= 0 then
            raise Program_Error with "could not execute " & args(1) & " (exit code " & Trim(Get_Exit_Status(proc)'Image, Left) & ")";
        end if;
    end Cmd_Exec;


    function Cmd_Exec(args: String_Vectors.Vector; env: String_Maps.Map := Empty_Map; cwd: String := "") return String is
        use all type
            Util.Processes.Process,
            Util.Streams.Input_Stream,
            Ada.Streams.Stream_Element_Offset;

        proc: Util.Processes.Process;
        result: Unbounded_String;

    begin
        if cwd'Length /= 0 then
            Set_Working_Directory(proc, cwd);
        end if;
        for it in env.Iterate loop
            Set_Environment(proc, Key(it), Element(it));
        end loop;

        Util.Processes.Spawn(proc, args, Util.Processes.READ);
        declare
            stream: constant not null Util.Streams.Input_Stream_Access := Get_Output_Stream(proc);
            data: Ada.Streams.Stream_Element_Array(1..4096);
            last: Ada.Streams.Stream_Element_Count;
        begin
            loop
                stream.Read(data, last);
                exit when last < data'First;
                for x of data(data'First .. last) loop
                    Append(result, Character'Val(x));
                end loop;
            end loop;
        end;

        Util.Processes.Wait(proc);
        if Util.Processes.Get_Exit_Status(proc) /= 0 then
            raise Program_Error with "could not execute " & args(1) & " (exit code " & Trim(Util.Processes.Get_Exit_Status(proc)'Image, Left) & ")";
        end if;

        return To_String(result);
    end Cmd_Exec;
end Utility;
