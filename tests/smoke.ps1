$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$env:CLAUDE_PORTABLE_BIN = Join-Path $Repo 'tests\fake-claude.cmd'

function Get-RealPath([string]$p) {
    $parts = $p.TrimEnd('\').Split('\')
    $acc = $parts[0].ToUpper() + '\'
    foreach ($c in $parts | Select-Object -Skip 1) { $acc = Join-Path $acc @(Get-ChildItem -LiteralPath $acc -Filter $c -Force)[0].Name }
    $acc
}
$tmp = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) "claude-portable-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
$T = Get-RealPath $tmp.FullName

$script:fails = 0
function Check([string]$name, [scriptblock]$test) {
    $ok = try { [bool](& $test) } catch { $false }
    if ($ok) { Write-Host "  ok    $name" -ForegroundColor Green } else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
}
function Launch([string]$at) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$T\$at\drive\system\claude-portable.ps1" "$T\$at\drive\Projects\App" @args | Out-Null
}
function Move-Drive([string]$from, [string]$to) { Move-Item "$T\$from\drive" "$T\$to\drive" }
function SessionDir([string]$at) { @(Get-ChildItem "$T\$at\drive\data\projects" -Directory | Where-Object Name -like "*-$at-drive-Projects-App")[0] }
function Newest($dir) { Get-ChildItem $dir.FullName -Filter *.jsonl | Sort-Object LastWriteTime | Select-Object -Last 1 }
function FileHas([string]$file, [string]$text) { [IO.File]::ReadAllText($file).Contains($text) }
function Lines($file) { @(Get-Content $file.FullName).Count }

try {
    New-Item -ItemType Directory -Force "$T\a\drive\Projects\App", "$T\b", "$T\c" | Out-Null
    Copy-Item -Recurse (Join-Path $Repo 'system') "$T\a\drive\"

    Write-Host 'First computer'
    $D = "$T\a\drive\data"
    Launch a --new
    $A = SessionDir a
    Check 'creates a session folder named after the path' { $A }
    Check 'starts a conversation' { (Lines (Newest $A)) -eq 1 }
    Check 'passes --system-prompt-snapshot off and the context file' { FileHas "$D\fake-claude.log" '--system-prompt-snapshot off --append-system-prompt-file' }
    Check 'seeds the /handoff command' { Test-Path "$D\commands\handoff.md" }
    New-Item -ItemType File "$($A.FullName)\._resource-fork.jsonl" | Out-Null

    Write-Host 'Second computer'
    Move-Drive a b; $D = "$T\b\drive\data"
    Launch b --continue
    $B = SessionDir b
    Check 'brings the conversation over and continues it' { (Lines (Newest $B)) -eq 2 }
    Check 'skips macOS resource-fork files' { -not (Test-Path "$($B.FullName)\._resource-fork.jsonl") }
    Check 'tells Claude where the project lived before' { FileHas "$D\portable\run\App.md" "$T\a\drive\Projects\App" }
    Check 'passes --continue' { FileHas "$D\fake-claude.log" '--continue' }
    Check 'remembers both paths' { @(Get-Content "$D\portable\projects\App.tsv" | Where-Object { $_ }).Count -eq 2 }

    Write-Host 'Back on the first computer'
    Set-Content "$D\portable\handoff\App.md" 'Build the Swift target on macOS next.'
    Move-Drive b a; $D = "$T\a\drive\data"
    Launch a --continue
    Check 'picks up what happened on the second computer' { (Lines (Newest (SessionDir a))) -eq 3 }
    Check 'includes the handoff note in the context' { FileHas "$D\portable\run\App.md" 'Build the Swift target' }

    Write-Host 'A computer where Claude Code stores the session somewhere unexpected'
    Move-Drive a c; $D = "$T\c\drive\data"
    $env:FAKE_CLAUDE_DIR = 'elsewhere'
    Launch c --new
    $tsv = Get-Content "$D\portable\projects\App.tsv"
    Check 'learns the real session folder' { $tsv | Where-Object { $_ -like "elsewhere`t*" } }
    Check 'forgets the predicted one' { -not ($tsv | Where-Object { $_ -like '*-c-drive-Projects-App`t*' }) }
    Check 'copies the history into the real folder' { Get-ChildItem "$D\projects\elsewhere" -Filter *.jsonl | Where-Object { (Lines $_) -eq 3 } }
    Launch c --continue
    Check 'continues there on the next launch' { (Get-Content "$D\fake-claude.log" | Select-Object -Last 1) -like '*--continue*' }
    Remove-Item Env:FAKE_CLAUDE_DIR

    Write-Host 'The project menu'
    New-Item -ItemType Directory -Force "$T\c\drive\Projects\Beta", "$T\outside" | Out-Null
    function Menu([string]$keys) {
        Push-Location $T
        try { $env:CLAUDE_PORTABLE_KEYS = $keys; & powershell -NoProfile -ExecutionPolicy Bypass -File "$T\c\drive\system\claude-portable.ps1" | Out-Null }
        finally { Remove-Item Env:CLAUDE_PORTABLE_KEYS; Pop-Location }
    }
    function Last { Get-Content "$D\fake-claude.log" | Select-Object -Last 1 }
    Menu 'enter'
    Check 'enter continues the most recent project' { (Last) -like '*\Projects\App | *--continue*' }
    Menu 'down n'
    Check 'arrows move to the next project' { (Last) -like '*\Projects\Beta | *' }
    Check 'n starts a new conversation' { (Last) -notlike '*--continue*' }
    Menu '+ text=Gamma'
    Check '+ creates a project' { Test-Path "$T\c\drive\Projects\Gamma" }
    Check 'and opens it' { (Last) -like '*\Projects\Gamma | *' }
    Menu "o text=$T\outside"
    Check 'o opens a folder on this computer' { (Last) -like '*\outside | *' }
    $count = @(Get-Content "$D\fake-claude.log").Count
    Menu 'q'
    Check 'q quits without opening anything' { @(Get-Content "$D\fake-claude.log").Count -eq $count }

    Write-Host 'Command line'
    Check '--help prints usage' { (& powershell -NoProfile -ExecutionPolicy Bypass -File "$T\c\drive\system\claude-portable.ps1" --help) -match '^Usage:' }
} finally {
    Remove-Item -Recurse -Force $tmp.FullName -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails) { Write-Host "$script:fails check(s) failed"; exit 1 }
Write-Host 'All checks passed'
