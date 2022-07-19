with Utility,
     Alpm;
use  Utility,
     Alpm;


package Cfg is
    Not_KV_Error: exception;
    Unknown_Key_Error: exception;
    Key_Context_Error: exception;
    Repeated_Key_Error: exception;
    Repeated_Value_Error: exception;

    tmpdir: constant String := Env.Value("TMPDIR", "/tmp");
    homedir: constant String := Env.Value("HOME");
    rootdir: constant String := Fs.Containing_Directory(Fs.Full_Name("/proc/self/exe"));
    repodir: constant String := rootdir & "/repo";

    makepkg_conf_path: constant String := rootdir & "/makepkg.conf";
    makepkg: Makepkg_Conf := Load_Data(Cmd_Exec([rootdir & "/makepkg-conf-toml", makepkg_conf_path]));


    procedure Filter_Packages(packages: in out String_Vectors.Vector; devel: OptBool := None);

    function Is_Srcinfo_Outdated(pkgbase: String) return Boolean;
    function Generate_Srcinfo(pkgbase: String) return String;

    procedure Update_Srcinfo(pkgbase: String; contents: String);
    function Update_Srcinfo(pkgbase: String) return String;

    function Read_Srcinfo(pkgbase: String; updatecache: Boolean) return String;
end Cfg;
