try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { Write-Verbose "No console to set the encoding on: $_" }

$ConsoleVT = [bool]$env:WT_SESSION
try {
    if (-not ('CP.ConsoleApi' -as [type])) {
        Add-Type -Namespace CP -Name ConsoleApi -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct FontInfo {
    public uint cbSize; public uint nFont; public short X; public short Y;
    public int FontFamily; public int FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
}
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref FontInfo f);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref FontInfo f);
'@
    }
    $h = [CP.ConsoleApi]::GetStdHandle(-11)
    $mode = [uint32]0
    if ([CP.ConsoleApi]::GetConsoleMode($h, [ref]$mode)) { $ConsoleVT = [CP.ConsoleApi]::SetConsoleMode($h, $mode -bor 4) -or $ConsoleVT }

    if (-not $env:WT_SESSION) {
        $f = New-Object CP.ConsoleApi+FontInfo
        $f.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($f)
        if ([CP.ConsoleApi]::GetCurrentConsoleFontEx($h, $false, [ref]$f) -and -not ($f.FontFamily -band 4)) {
            $f.FaceName = 'Consolas'; $f.FontFamily = 54; $f.FontWeight = 400; $f.X = 0; $f.Y = 18
            [void][CP.ConsoleApi]::SetCurrentConsoleFontEx($h, $false, [ref]$f)
        }
    }
} catch { Write-Verbose "Could not set up the console: $_" }
