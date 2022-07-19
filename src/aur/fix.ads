with Utility;
use  Utility;

with Ada.Command_Line;
use  Ada.Command_Line;


function Fix(
    pkgbases: in out String_Vectors.Vector
) return Exit_Status;
