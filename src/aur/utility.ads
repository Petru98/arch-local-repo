with Ada.Strings.Unbounded,
     Ada.Strings.Hash,
     Ada.Containers.Indefinite_Hashed_Maps,
     Ada.Environment_Variables,
     Ada.Directories;
use  Ada.Strings,
     Ada.Strings.Unbounded,
     Ada.Containers;

with Util.Strings.Vectors;


package Utility is
    package Fs renames Ada.Directories;

    package String_Vectors renames Util.Strings.Vectors;
    use all type String_Vectors.Vector;

    package Env renames Ada.Environment_Variables;

    package String_Maps is new Ada.Containers.Indefinite_Hashed_Maps(
        Key_Type        => String,
        Element_Type    => String,
        Hash            => Ada.Strings.Hash,
        Equivalent_Keys => "=");
    use String_Maps;

    type OptBool is (None, False, True);


    function Starts_With(str, prefix: String) return Boolean;
    function Ends_With(str, suffix: String) return Boolean;

    function Starts_With(str, prefix: Unbounded_String) return Boolean;
    function Ends_With(str, suffix: Unbounded_String) return Boolean;

    function Next_Line(str: String; linebeg: in out Positive; lineend: in out Natural) return Boolean;
    function Cmp_ModTime(path1, path2: String) return Integer;

    function Read_File(path: String) return String;
    procedure Write_File(path: String; contents: String);

    procedure Cmd_Exec(
        args: String_Vectors.Vector;
        env: String_Maps.Map := Empty_Map;
        cwd: String := ""
    );
    function Cmd_Exec(
        args: String_Vectors.Vector;
        env: String_Maps.Map := Empty_Map;
        cwd: String := ""
    ) return String;
end Utility;
