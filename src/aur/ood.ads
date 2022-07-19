with Utility;
use  Utility;

with Ada.Command_Line;
use  Ada.Command_Line;


function Ood(
    pkgbases: in out String_Vectors.Vector;
    devel: OptBool := None
) return Exit_Status;
