with Utility,
     Build,
     Fix,
     Ood;
use  Utility,
     Utility.String_Vectors;

with Ada.Containers,
     Ada.Command_Line,
     Ada.Text_IO;
use  Ada.Containers,
     Ada.Command_Line,
     Ada.Text_IO;

with GNAT.Command_Line;
use  GNAT.Command_Line;

with Util.Commands.Drivers,
     Util.Commands.Parsers,
     Util.Commands.Parsers.GNAT_Parser;
use  Util.Commands;


procedure Aur is
    function To_Vector(args: Argument_List'Class) return String_Vectors.Vector is
        count: constant Natural := Get_Count(Args);
        vector: String_Vectors.Vector := Empty(Count_Type(count));
    begin
        vector.Reserve_Capacity(Count_Type(count));
        for i in 1 .. count loop
            vector.Append(Get_Argument(Args, i));
        end loop;
        return vector;
    end To_Vector;


    type Context_Type is new Integer;
    package Drivers is new Util.Commands.Drivers
        (Context_Type  => Context_Type,
         Config_Parser => Util.Commands.Parsers.GNAT_Parser.Config_Parser,
         Driver_Name   => "aur");



    procedure Build_Callback(Switch, Value: String);
    type Build_Command is new Drivers.Command_Type with record
        devel: OptBool := None;
    end record;


    overriding procedure Setup(
        Command : in out Build_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type);

    overriding procedure Execute(
        Command : in out Build_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type);

    overriding procedure Help(
        Command   : in out Build_Command;
        Name      : in String;
        Context   : in out Context_Type);


    overriding procedure Setup(
        Command : in out Build_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
    begin
        Define_Switch(Config, Build_Callback'Unrestricted_Access,
            Long_Switch => "--devel",
            Help => "");
    end Setup;


    overriding procedure Execute(
        Command : in out Build_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
        pkgbases: String_Vectors.Vector := To_Vector(Args);
    begin
        Set_Exit_Status(Build(pkgbases, Command.devel));
    end Execute;


    overriding procedure Help(
        Command   : in out Build_Command;
        Name      : in String;
        Context   : in out Context_Type)
    is
        config: Drivers.Config_Type;
    begin
        Command.Setup(config, context);
        Display_Help(config);
    end Help;




    procedure Fix_Callback(Switch, Value: String);
    type Fix_Command is new Drivers.Command_Type with record
        null;
    end record;


    overriding procedure Setup(
        Command : in out Fix_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type);

    overriding procedure Execute(
        Command : in out Fix_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type);

    overriding procedure Help(
        Command   : in out Fix_Command;
        Name      : in String;
        Context   : in out Context_Type);


    overriding procedure Setup(
        Command : in out Fix_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
    begin
        null;
    end Setup;


    overriding procedure Execute(
        Command : in out Fix_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
        pkgbases: String_Vectors.Vector := To_Vector(Args);
    begin
        Set_Exit_Status(Fix(pkgbases));
    end Execute;


    overriding procedure Help(
        Command   : in out Fix_Command;
        Name      : in String;
        Context   : in out Context_Type)
    is
        config: Drivers.Config_Type;
    begin
        Command.Setup(config, context);
        Display_Help(config);
    end Help;




    procedure Ood_Callback(Switch, Value: String);
    type Ood_Command is new Drivers.Command_Type with record
        devel: OptBool := None;
    end record;


    overriding procedure Setup(
        Command : in out Ood_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type);

    overriding procedure Execute(
        Command : in out Ood_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type);

    overriding procedure Help(
        Command   : in out Ood_Command;
        Name      : in String;
        Context   : in out Context_Type);


    overriding procedure Setup(
        Command : in out Ood_Command;
        Config  : in out Util.Commands.Parsers.GNAT_Parser.Config_Type;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
    begin
        Define_Switch(Config, Ood_Callback'Unrestricted_Access,
            Long_Switch => "--devel",
            Help => "");
    end Setup;


    overriding procedure Execute(
        Command : in out Ood_Command;
        Name    : in String;
        Args    : in Argument_List'Class;
        Context : in out Context_Type)
    is
        pragma Unreferenced(Context);
        pkgbases: String_Vectors.Vector := To_Vector(Args);
    begin
        Set_Exit_Status(Ood(pkgbases, Command.devel));
    end Execute;


    overriding procedure Help(
        Command   : in out Ood_Command;
        Name      : in String;
        Context   : in out Context_Type)
    is
        config: Drivers.Config_Type;
    begin
        Command.Setup(config, context);
        Display_Help(config);
    end Help;




    helpcmd: aliased Drivers.Help_Command_Type;
    buildcmd: aliased Build_Command;
    fixcmd: aliased Fix_Command;
    oodcmd: aliased Ood_Command;


    procedure Build_Callback(Switch, Value: String) is
        pragma Unreferenced(Value);
    begin
        if Switch = "--devel" then
            buildcmd.devel := True;
        elsif Switch = "--no-devel" then
            buildcmd.devel := False;
        end if;
    end Build_Callback;


    procedure Fix_Callback(Switch, Value: String) is
        pragma Unreferenced(Value);
    begin
        null;
    end Fix_Callback;


    procedure Ood_Callback(Switch, Value: String) is
        pragma Unreferenced(Value);
    begin
        if Switch = "--devel" then
            oodcmd.devel := True;
        elsif Switch = "--no-devel" then
            oodcmd.devel := False;
        end if;
    end Ood_Callback;


    driver: Drivers.Driver_Type;
    args: Util.Commands.Default_Argument_List(1);
    context: Context_Type := 0;


begin
    driver.Add_Command("help", helpcmd'Access);
    driver.Add_Command("build", buildcmd'Access);
    driver.Add_Command("fix", fixcmd'Access);
    driver.Add_Command("ood", oodcmd'Access);

    if Ada.Command_Line.Argument_Count = 0 then
        driver.Execute("help", args, context);
        return;
    end if;

    driver.Execute(Ada.Command_Line.Argument(1), args, context);
end Aur;
