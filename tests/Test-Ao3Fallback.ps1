param([string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-fallback-test'))

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
$app = Join-Path $run 'app'
New-Item -ItemType Directory -Path (Join-Path $app 'user'), (Join-Path $run 'books'), (Join-Path $run 'tmp') -Force | Out-Null
try {
    $script = Get-Content -LiteralPath (Join-Path $source 'Download AO3 with FanFicFare.ps1') -Raw
    $anchor = '$providedUrls = @($urls)'
    if ($script.IndexOf($anchor, [StringComparison]::Ordinal) -lt 0) { throw 'Could not locate URL selection.' }
    $stubs = @'
function Invoke-NativeAo3Download { param([string] $WorkUrl) return $null }
function Download-FichubFile { param([string] $StoryUrl, [switch] $RequireNewChapters) return $null }
function Invoke-FanFicFareDownload {
    param([string[]] $DownloadUrls, $Attempt, [string[]] $ExtraConfigPaths)
    Write-Host 'TEST_FANFICFARE_INVOKED'
    return [pscustomobject]@{ ExitCode = 1; Stdout = 'Failed: synthetic'; Stderr = ''; TimedOut = $false }
}
'@
    $script = $script.Replace($anchor, "$stubs`r`n$anchor")
    [IO.File]::WriteAllText((Join-Path $app 'Download AO3 with FanFicFare.ps1'), $script, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $app 'dummy.exe'), '', [Text.UTF8Encoding]::new($false))
    $settings = @(
        '[paths]',
        "output_dir=$(Join-Path $run 'books')",
        "log_dir=$(Join-Path $run 'logs')",
        'fanficfare_exe=dummy.exe',
        '',
        '[download]',
        'format=epub',
        'read_clipboard=false',
        'retry_failed_urls=false',
        'prefer_native=true',
        'use_fichub=true',
        'use_fichub_for_ao3=true',
        'open_after_download=false',
        '',
        '[updates]',
        'check_for_updates=false',
        '',
        '[accessibility]',
        'pause_on_error=false'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings, [Text.UTF8Encoding]::new($false))
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'Download AO3 with FanFicFare.ps1') -SkipUpdateCheck 'https://archiveofourown.org/works/123' 2>&1 | Out-String
    }
    finally {
        $env:TEMP = $oldTemp
    }
    if ($output -notmatch 'TEST_FANFICFARE_INVOKED' -or $output -notmatch 'FicHub has no newer copy; trying FanFicFare backup') {
        throw "Stale FicHub did not reach FanFicFare: $output"
    }
    $queued = Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt')
    if ('https://archiveofourown.org/works/123' -notin $queued) {
        throw 'Failed AO3 URL was not retained in the queue.'
    }
    Write-Host 'Stale FicHub fallback test passed.'
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
