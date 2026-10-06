$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'console.ps1')

$Root = Split-Path -Parent $PSScriptRoot
$Data = Join-Path $Root 'data'
$Portable = Join-Path $Data 'portable'
$ProjectsDir = Join-Path $Root 'Projects'
$Plat = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' }
$OsName = 'Windows'
$Invariant = [Globalization.CultureInfo]::InvariantCulture

$Usage = @'
Usage:
  claude-portable [PROJECT_DIR] [--new | --continue | --resume] [--name NAME] [-- CLAUDE_ARGS...]
  claude-portable --import DIR [--name NAME]

  PROJECT_DIR   Project to open. Without it you get the project menu.
  --new         Start a new conversation.
  --continue    Continue the most recent conversation (the default when one exists).
  --resume      Pick a conversation from a list.
  --name NAME   Project name used to match this folder across computers (default: folder name).
  --import DIR  Copy this computer's existing Claude Code history for DIR onto the drive.
  --            Everything after it is passed to claude unchanged.

Environment:
  CLAUDE_PORTABLE_BIN   Use this claude executable instead of the one in bin\.
  NO_COLOR              Turn colours off.
'@

function Encode([string]$p) { $p -replace '[^a-zA-Z0-9]', '-' }
function KeyOf([string]$name) { $name -replace '[^A-Za-z0-9._-]', '_' }
function Now { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Get-RealPath([string]$p) {
    $parts = [IO.Path]::GetFullPath($p).TrimEnd('\').Split('\')
    $acc = $parts[0].ToUpper() + '\'
    foreach ($c in $parts | Select-Object -Skip 1) {
        $m = @(Get-ChildItem -LiteralPath $acc -Filter $c -Force -ErrorAction SilentlyContinue)[0]
        $acc = Join-Path $acc $(if ($m) { $m.Name } else { $c })
    }
    $acc
}

function Sync-Dir([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { return 0 }
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File -Force) {
        if ($f.Name -like '._*' -or $f.Name -eq '.DS_Store') { continue }
        $d = Join-Path $dst $f.FullName.Substring($src.Length).TrimStart('\')
        $t = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        $copy = (-not $t) -or $(if ($f.Extension -eq '.jsonl') { $f.Length -gt $t.Length } else { $f.LastWriteTimeUtc -gt $t.LastWriteTimeUtc })
        if ($copy) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $d) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $d -Force
            $n++
        }
    }
    $n
}

function Read-AliasList([string]$key) {
    $file = Join-Path $Portable "projects\$key.tsv"
    if (-not (Test-Path $file)) { return @() }
    @(Get-Content $file -Encoding UTF8 | Where-Object { $_ } | ForEach-Object {
        $c = $_ -split "`t"
        [pscustomobject]@{ Enc = $c[0]; Path = $c[1]; Os = $c[2]; Host = $c[3]; Last = $c[4] }
    })
}

function Save-Alias([string]$key, [string]$enc, [string]$path, [string]$drop) {
    $list = @(Read-AliasList $key | Where-Object { $_.Enc -ne $enc -and $_.Enc -ne $drop })
    $list += [pscustomobject]@{ Enc = $enc; Path = $path; Os = $OsName; Host = $env:COMPUTERNAME; Last = (Now) }
    New-Item -ItemType Directory -Force (Join-Path $Portable 'projects') | Out-Null
    $lines = $list | ForEach-Object { ($_.Enc, $_.Path, $_.Os, $_.Host, $_.Last) -join "`t" }
    [IO.File]::WriteAllLines((Join-Path $Portable "projects\$key.tsv"), [string[]]$lines)
}

function Get-ToolchainList {
    $found = foreach ($t in 'git', 'swift', 'xcodebuild', 'node', 'python', 'dotnet', 'cargo', 'go', 'java') {
        if (Get-Command $t -ErrorAction SilentlyContinue) { $t }
    }
    if ($found) { $found -join ', ' } else { '(none detected)' }
}

$Interactive = -not [Console]::IsOutputRedirected
$e = [char]27
if (($ConsoleVT -and $Interactive -and -not $env:NO_COLOR) -or $env:FORCE_COLOR) {
    $RESET = "$e[0m"; $BOLD = "$e[1m"; $DIM = "$e[38;5;245m"; $ACCENT = "$e[38;5;209m"
} else {
    $RESET = $BOLD = $DIM = $ACCENT = ''
}

$Scripted = $null -ne $env:CLAUDE_PORTABLE_KEYS
$script:ScriptedKeys = @(if ($Scripted) { $env:CLAUDE_PORTABLE_KEYS -split ' ' | Where-Object { $_ } })

function Read-UiKey {
    if ($Scripted) {
        if ($script:ScriptedKeys.Count -eq 0) { return 'q' }
        $k = $script:ScriptedKeys[0]
        $script:ScriptedKeys = @($script:ScriptedKeys | Select-Object -Skip 1)
        return $k
    }
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
        'UpArrow' { 'up' } 'DownArrow' { 'down' } 'Enter' { 'enter' } 'Escape' { 'esc' }
        default { [string]$k.KeyChar }
    }
}

function Show-UiCursor([bool]$visible = $true) {
    if ($Interactive) { try { [Console]::CursorVisible = $visible } catch { Write-Verbose "No cursor: $_" } }
}

function Read-UiText([string]$prompt) {
    if ($Scripted) { $k = Read-UiKey; if ($k -like 'text=*') { return $k.Substring(5) } else { return '' } }
    [Console]::Write("`n  $BOLD$prompt$RESET ")
    Show-UiCursor
    $t = [Console]::ReadLine()
    Show-UiCursor $false
    "$t"
}

function Clear-Ui {
    if (-not $Interactive) { return }
    if ($ConsoleVT) { [Console]::Write("$e[H$e[J") } else { [Console]::Clear() }
}

function Get-UiWidth {
    $c = 80
    try { $c = [Console]::WindowWidth } catch { Write-Verbose "No console width: $_" }
    [Math]::Max(46, [Math]::Min(80, $c - 4))
}

function Format-Cell([string]$s, [int]$w) {
    if ($w -lt 1) { $w = 1 }
    if ($s.Length -gt $w) { $s = $s.Substring(0, $w - 1) + '…' }
    $s.PadRight($w)
}

function Format-ShortPath([string]$p, [int]$max = 40) {
    $parts = $p.Split('\')
    if ($p.Length -le $max -or $parts.Count -le 3) { return $p }
    "$($parts[0])\…\$($parts[-2])\$($parts[-1])"
}

function Format-Hint([string]$key, [string]$label) { "$BOLD$key$RESET $DIM$label$RESET" }

function Format-When([string]$iso) {
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse($iso, $Invariant, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$t)) { return '' }
    $day = $t.ToLocalTime().Date
    $ago = ([datetime]::Today - $day).Days
    if ($ago -eq 0) { 'today' }
    elseif ($ago -eq 1) { 'yesterday' }
    elseif ($day.Year -eq [datetime]::Today.Year) { $day.ToString('MMM d', $Invariant) }
    else { $day.ToString('MMM d, yyyy', $Invariant) }
}

function Get-ClaudeVersion {
    $f = Join-Path $Root "bin\$Plat\VERSION"
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() }
}

function Get-ProjectList {
    $rows = @()
    foreach ($d in Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name.StartsWith('.')) { continue }
        $last = Read-AliasList (KeyOf $d.Name) | Sort-Object Last | Select-Object -Last 1
        $rows += [pscustomobject]@{
            Name = $d.Name; Path = $d.FullName; Last = $(if ($last) { $last.Last } else { '' })
            Detail = $(if ($last) { "$($last.Os) · $(Format-When $last.Last)" } else { 'not opened yet' })
        }
    }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Portable 'projects') -Filter *.tsv -ErrorAction SilentlyContinue) {
        foreach ($a in Read-AliasList $f.BaseName) {
            if ($a.Os -ne $OsName -or $a.Path.StartsWith($ProjectsDir + '\', 'OrdinalIgnoreCase')) { continue }
            if (-not (Test-Path -LiteralPath $a.Path -PathType Container) -or ($rows | Where-Object { $_.Path -eq $a.Path })) { continue }
            $when = Format-When $a.Last
            $rows += [pscustomobject]@{ Name = (Split-Path -Leaf $a.Path); Path = $a.Path; Last = $a.Last; Detail = (Format-ShortPath $a.Path) + $(if ($when) { " · $when" }) }
        }
    }
    @($rows | Sort-Object @{ Expression = 'Last'; Descending = $true }, Name)
}

function Write-Header {
    $w = Get-UiWidth
    $v = Get-ClaudeVersion
    $right = if ($v) { "Claude Code $v" } else { 'Claude Code not downloaded yet' }
    Clear-Ui
    [Console]::Write("`n  $ACCENT$BOLD›_$RESET ${BOLD}Claude Portable$RESET$(' ' * [Math]::Max(1, $w - 18 - $right.Length))$DIM$right$RESET`n")
    [Console]::Write("  $DIM$('─' * $w)$RESET`n`n")
}

function Write-Menu($projects, [int]$selected, [string]$message) {
    $w = Get-UiWidth
    Write-Header
    $out = New-Object Text.StringBuilder
    if ($projects.Count -eq 0) {
        [void]$out.Append("  No projects yet. Press $BOLD+$RESET to create one on the drive,`n  or ${BOLD}o$RESET to open a folder on this computer.`n")
    } else {
        [void]$out.Append("  ${DIM}Pick up where you left off.$RESET`n`n")
        $nw = [Math]::Min(26, ($projects | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
        $dw = $w - $nw - 4
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $p = $projects[$i]
            if ($i -eq $selected) { [void]$out.Append("  $ACCENT$BOLD›$RESET $BOLD$(Format-Cell $p.Name $nw)$RESET  $(Format-Cell $p.Detail $dw)`n") }
            else { [void]$out.Append("    $(Format-Cell $p.Name $nw)  $DIM$(Format-Cell $p.Detail $dw)$RESET`n") }
        }
    }
    if ($message) { [void]$out.Append("`n  $ACCENT$message$RESET`n") }
    [void]$out.Append("`n  $DIM$('─' * $w)$RESET`n")
    if ($projects.Count -gt 0) { [void]$out.Append("  $(Format-Hint '↑↓' 'choose')   $(Format-Hint 'enter' 'continue')   $(Format-Hint 'n' 'new chat')`n") }
    [void]$out.Append("  $(Format-Hint '+' 'new project')   $(Format-Hint 'o' 'open folder')   $(Format-Hint 'u' 'update')   $(Format-Hint 'q' 'quit')`n")
    [Console]::Write($out.ToString())
}

function Invoke-ClaudeUpdate {
    Write-Header
    [Console]::Write("  ${BOLD}Checking for a newer Claude Code…$RESET`n`n")
    Show-UiCursor
    try { & (Join-Path $PSScriptRoot 'setup.ps1') all } catch { [Console]::Write("`n  ${ACCENT}The update didn't finish: $($_.Exception.Message)$RESET`n") }
    Show-UiCursor $false
    [Console]::Write("`n  $(Format-Hint 'enter' 'back')`n")
    if (-not $Scripted) { [void](Read-UiKey) }
}

function Select-Project {
    $projects = @(Get-ProjectList)
    $sel = 0; $msg = ''
    Show-UiCursor $false
    try {
        while ($true) {
            Write-Menu $projects $sel $msg
            $msg = ''
            $k = Read-UiKey
            switch -CaseSensitive ($k) {
                { $_ -in 'up', 'k' } { if ($sel -gt 0) { $sel-- } }
                { $_ -in 'down', 'j' } { if ($sel -lt $projects.Count - 1) { $sel++ } }
                { $_ -in 'enter', 'n', 'N' } {
                    if ($projects.Count -gt 0) { return @($projects[$sel].Path, $(if ($k -eq 'enter') { 'continue' } else { 'new' })) }
                }
                { $_ -in '+', '=' } {
                    $t = (Read-UiText 'Name for the new project:').Trim()
                    if (-not $t) { }
                    elseif ($t.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $t.StartsWith('.')) { $msg = 'Names can''t contain \ / : * ? " < > | or start with a dot.' }
                    elseif (Test-Path -LiteralPath (Join-Path $ProjectsDir $t)) { $msg = "There's already a project called $t." }
                    else { return @((New-Item -ItemType Directory -Force (Join-Path $ProjectsDir $t)).FullName, 'new') }
                }
                { $_ -in 'o', 'O' } {
                    $p = (Read-UiText 'Folder to open (you can drag it into this window):').Trim().Trim('"')
                    if (-not $p) { }
                    elseif (Test-Path -LiteralPath $p -PathType Container) { return @($p, 'continue') }
                    else { $msg = "Can't find that folder." }
                }
                { $_ -in 'u', 'U' } { Invoke-ClaudeUpdate }
                { $_ -in 'q', 'Q', 'esc' } { Clear-Ui; exit 0 }
            }
        }
    } finally { Show-UiCursor }
}

function Resolve-ClaudeBinary {
    if ($env:CLAUDE_PORTABLE_BIN) { return $env:CLAUDE_PORTABLE_BIN }
    $b = Join-Path $Root "bin\$Plat\claude.exe"
    if (-not (Test-Path $b)) {
        Write-Header
        [Console]::Write("  ${BOLD}Claude Code isn't on this drive yet.$RESET`n`n")
        [Console]::Write("  Download it for Windows and Mac now? It's about 700 MB and only needed once.`n")
        [Console]::Write("  ${DIM}It comes straight from Anthropic, and every file is checked before it's saved.$RESET`n`n")
        [Console]::Write("  $(Format-Hint 'enter' 'download')   $(Format-Hint 'q' 'cancel')`n")
        if ((Read-UiKey) -in 'enter', 'y') {
            [Console]::Write("`n")
            try { & (Join-Path $PSScriptRoot 'setup.ps1') all } catch { [Console]::Write("`n  ${ACCENT}The download didn't finish: $($_.Exception.Message)$RESET`n") }
        }
    }
    if (Test-Path $b) { return $b }
    $sys = Get-Command claude -ErrorAction SilentlyContinue
    if ($sys) { return $sys.Source }
    [Console]::Write("`n  Claude Code isn't available. Open Claude Portable again to download it.`n")
    exit 1
}

$project = $null; $mode = $null; $name = $null; $import = $null; $pass = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch -regex ($a) {
        '^--$'                       { if ($i + 1 -lt $args.Count) { $pass += $args[($i + 1)..($args.Count - 1)] }; $i = $args.Count; break }
        '^(-h|--?help|/\?)$'         { Write-Host $Usage; exit 0 }
        '^--?(new|continue|resume)$' { $mode = $Matches[1]; break }
        '^--?name$'                  { $name = $args[++$i]; break }
        '^--?import$'                { $import = $args[++$i]; break }
        default { if (-not $project -and (Test-Path -LiteralPath $a -PathType Container)) { $project = $a } else { $pass += $a } }
    }
}

New-Item -ItemType Directory -Force $Data, $Portable, $ProjectsDir | Out-Null
$tpl = Join-Path $PSScriptRoot 'template'
foreach ($f in Get-ChildItem -LiteralPath $tpl -Recurse -File) {
    $d = Join-Path $Data $f.FullName.Substring($tpl.Length).TrimStart('\')
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $d) | Out-Null
        Copy-Item -LiteralPath $f.FullName $d
    }
}

try {
    if (-not (Test-Path (Join-Path $Root '.git')) -and (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))).DriveType -eq 'Removable') {
        foreach ($n in 'system', 'bin', 'data') {
            $d = Get-Item -LiteralPath (Join-Path $Root $n) -Force -ErrorAction SilentlyContinue
            if ($d) { $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::Hidden }
        }
    }
} catch { Write-Verbose "Could not hide the support folders: $_" }

if ($import) {
    $full = Get-RealPath $import
    $enc = Encode $full
    $src = Join-Path $env:USERPROFILE ".claude\projects\$enc"
    if (-not (Test-Path $src)) { throw "No Claude Code history for $full on this computer ($src)" }
    $key = KeyOf $(if ($name) { $name } else { Split-Path -Leaf $full })
    $n = Sync-Dir $src (Join-Path $Data "projects\$enc")
    Save-Alias $key $enc $full
    Write-Host "Imported $n file(s) into project '$key'. Its conversations now continue on any computer."
    Write-Host "Next: copy the project folder to $ProjectsDir\$key, or open a folder with the same name on the other computer."
    exit 0
}

if (-not $project) {
    $cwd = (Get-Location).Path
    if ($cwd.StartsWith($ProjectsDir + '\', 'OrdinalIgnoreCase')) {
        $project = Join-Path $ProjectsDir ($cwd.Substring($ProjectsDir.Length + 1) -split '\\')[0]
    } else {
        $project, $picked = Select-Project
        if (-not $mode) { $mode = $picked }
    }
}
$Bin = Resolve-ClaudeBinary
$ProjPath = Get-RealPath $project
$Key = KeyOf $(if ($name) { $name } else { Split-Path -Leaf $ProjPath })
$aliases = @(Read-AliasList $Key)
$known = $aliases | Where-Object { $_.Path -eq $ProjPath -and $_.Os -eq $OsName } | Sort-Object Last | Select-Object -Last 1
$Enc = if ($known) { $known.Enc } else { Encode $ProjPath }
$SessDir = Join-Path $Data "projects\$Enc"

$synced = 0
foreach ($al in $aliases | Where-Object { $_.Enc -ne $Enc }) { $synced += Sync-Dir (Join-Path $Data "projects\$($al.Enc)") $SessDir }
Save-Alias $Key $Enc $ProjPath

$handoff = Join-Path $Portable "handoff\$Key.md"
New-Item -ItemType Directory -Force (Split-Path $handoff), (Join-Path $Portable 'run') | Out-Null
$others = @($aliases | Where-Object { $_.Enc -ne $Enc } | ForEach-Object { "| $($_.Os) | $($_.Host) | ``$($_.Path)`` | $($_.Last) |" })
$ctx = @"
# Claude Portable

This Claude Code installation runs from a portable drive shared between several computers (e.g. Windows and macOS). Conversation history and memory travel with the drive, so earlier messages in this conversation may have been written on a different machine, with different paths, shell and toolchains.

## Current machine (authoritative; overrides anything earlier in the conversation)
- OS: $OsName ($Plat), host: $env:COMPUTERNAME
- Project directory: ``$ProjPath``
- Toolchains on PATH: $(Get-ToolchainList)

## This project on other machines
$(if ($others) { "| OS | Host | Path | Last used (UTC) |`n|---|---|---|---|`n" + ($others -join "`n") + "`n`nWhen earlier messages mention those paths, map them to the current project directory. Files may have changed since then: re-read before editing, and don't assume a build or test result from another machine holds here." } else { '(none yet)' })

## Handoff note
File: ``$handoff``
$(if (Test-Path $handoff) { "`n" + (Get-Content $handoff -Raw -Encoding UTF8) } else { '(none yet)' })

When the user runs /handoff or says they are switching computers, rewrite that file with the current state and next steps (what must be done on the other machine, e.g. building Swift on macOS).
"@
$ctxFile = Join-Path $Portable "run\$Key.md"
[IO.File]::WriteAllText($ctxFile, $ctx, (New-Object Text.UTF8Encoding $false))

$hasSessions = [bool](Get-ChildItem -LiteralPath $SessDir -Filter *.jsonl -File -ErrorAction SilentlyContinue)
if (-not $mode) { $mode = 'continue' }
if ($mode -eq 'continue' -and -not $hasSessions) { $mode = 'new' }
$claudeArgs = @('--system-prompt-snapshot', 'off', '--append-system-prompt-file', $ctxFile)
if ($mode -eq 'continue') { $claudeArgs += '--continue' }
if ($mode -eq 'resume') { $claudeArgs += '--resume' }
$claudeArgs += $pass

$what = switch ($mode) { 'continue' { 'continuing your last conversation' } 'resume' { 'pick a conversation' } default { 'new conversation' } }
$start = Get-Date
$before = @(Get-ChildItem -LiteralPath (Join-Path $Data 'projects') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
$env:CLAUDE_CONFIG_DIR = $Data
$env:DISABLE_AUTOUPDATER = '1'
$env:CLAUDE_PORTABLE_ROOT = $Root
try { $Host.UI.RawUI.WindowTitle = "Claude · $Key" } catch { Write-Verbose "No window to title: $_" }
Clear-Ui
[Console]::Write("`n  $ACCENT$BOLD›_$RESET $BOLD$Key$RESET  $DIM$what$RESET`n")
if ($synced) { [Console]::Write("  ${DIM}Brought in $synced file(s) from your other computers.$RESET`n") }
[Console]::Write("`n")
Push-Location -LiteralPath $ProjPath
try { & $Bin @claudeArgs; $rc = $LASTEXITCODE } finally { Pop-Location }

$wrote = Get-ChildItem -LiteralPath $SessDir -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start }
$new = @(Get-ChildItem -LiteralPath (Join-Path $Data 'projects') -Directory -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Name })
if (-not $wrote -and $new.Count -eq 1) {
    Sync-Dir $SessDir $new[0].FullName | Out-Null
    Save-Alias $Key $new[0].Name $ProjPath $Enc
}
[Console]::Write("`n  $ACCENT$BOLD›_$RESET ${BOLD}Saved to the drive.$RESET ${DIM}Close this window before you eject it.$RESET`n`n")
exit $rc
