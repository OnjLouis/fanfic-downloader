param(
    [Parameter(Mandatory = $true)][string] $FixtureEpub,
    [string] $ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'),
    [Parameter(Mandatory = $true)][string] $ScratchParent
)

$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid scratch path.' }
$app = Join-Path $run 'app'
$logs = Join-Path $run 'logs'
New-Item -ItemType Directory -Path (Join-Path $app 'user'), $logs, (Join-Path $run 'tmp') -Force | Out-Null
$oldTemp = $env:TEMP
try {
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $app 'Download.ps1')
    $book = Join-Path $run 'fixture.epub'
    Copy-Item -LiteralPath $FixtureEpub -Destination $book
    $settings = "[paths]`r`noutput_dir=$run\books`r`nlog_dir=$logs`r`n[download]`r`nread_clipboard=false`r`n[accessibility]`r`npause_on_error=false"
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings)
    $current = Join-Path $logs 'downloader.log'
    $previous = Join-Path $logs 'downloader-previous.log'
    [IO.File]::WriteAllText($current, 'PARENT RUN: AO3 errors and earlier successful files')
    [IO.File]::WriteAllText($previous, 'PREVIOUS RUN')
    $env:TEMP = Join-Path $run 'tmp'
    $result = Join-Path $run 'result.json'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'Download.ps1') -PrepareOnly -PrepareInput $book -PrepareResult $result | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Preparation worker failed.' }
    if (-not (Test-Path -LiteralPath $current) -or -not (Test-Path -LiteralPath $previous) -or
        (Get-Content -LiteralPath $current -Raw) -ne 'PARENT RUN: AO3 errors and earlier successful files' -or
        (Get-Content -LiteralPath $previous -Raw) -ne 'PREVIOUS RUN') {
        throw 'Preparation worker rotated or truncated the parent download log.'
    }
    if (-not (Get-Content -LiteralPath $result -Raw | ConvertFrom-Json).Success) { throw 'Preparation did not validate.' }
    Write-Host 'Preparation worker preserved both download logs.'
}
finally {
    $env:TEMP = $oldTemp
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
