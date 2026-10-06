$ErrorActionPreference = 'Stop'
$cwd = (Get-Location).Path
$name = if ($env:FAKE_CLAUDE_DIR) { $env:FAKE_CLAUDE_DIR } else { $cwd -replace '[^a-zA-Z0-9]', '-' }
$dir = Join-Path $env:CLAUDE_CONFIG_DIR "projects\$name"
New-Item -ItemType Directory -Force $dir | Out-Null
Add-Content (Join-Path $env:CLAUDE_CONFIG_DIR 'fake-claude.log') ($cwd + ' | ' + ($args -join ' '))

$file = $null
if ($args -contains '--continue') {
    $file = Get-ChildItem $dir -Filter *.jsonl | Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object FullName
}
if (-not $file) { $file = Join-Path $dir "$([guid]::NewGuid()).jsonl" }
Add-Content $file ('{"type":"user","cwd":"' + ($cwd -replace '\\', '\\') + '"}')
