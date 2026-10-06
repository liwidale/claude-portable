$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'console.ps1')

$Root = Split-Path -Parent $PSScriptRoot
$Base = 'https://downloads.claude.ai/claude-code-releases'
$Version = 'stable'
$platforms = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -regex ($args[$i]) {
        '^-{1,2}version$' { $Version = $args[++$i] }
        '^all$'           { $platforms += 'win32-x64', 'darwin-arm64', 'darwin-x64' }
        default           { $platforms += $args[$i] }
    }
}
if (-not $platforms) {
    $platforms = @(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' })
}

if ($Version -notmatch '^\d+\.\d+\.\d+') { $Version = (Invoke-RestMethod "$Base/$Version").ToString().Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+') { throw 'Could not get a version from downloads.claude.ai' }
$manifest = Invoke-RestMethod "$Base/$Version/manifest.json"
Write-Host "Claude Code $Version"

foreach ($p in $platforms | Select-Object -Unique) {
    $info = $manifest.platforms.$p
    if (-not $info) { Write-Warning "Platform $p is not in the manifest"; continue }
    $dir = Join-Path $Root "bin\$p"
    $dest = Join-Path $dir $info.binary
    $verFile = Join-Path $dir 'VERSION'
    if ((Test-Path $dest) -and (Test-Path $verFile) -and (Get-Content $verFile -Raw).Trim() -eq $Version) {
        Write-Host "  $p is already $Version"; continue
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $tmp = "$dest.download"
    Write-Host ("  $p downloading {0:N0} MB..." -f ($info.size / 1MB))
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --progress-bar -o $tmp "$Base/$Version/$p/$($info.binary)"
        if ($LASTEXITCODE) { throw "Download of $p failed" }
    } else {
        Invoke-WebRequest "$Base/$Version/$p/$($info.binary)" -OutFile $tmp
    }
    if ((Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower() -ne $info.checksum) {
        Remove-Item -Force $tmp; throw "Checksum mismatch for $p, the download was deleted"
    }
    Move-Item -Force $tmp $dest
    [IO.File]::WriteAllText($verFile, "$Version`n")
    Write-Host "  $p OK"
}
