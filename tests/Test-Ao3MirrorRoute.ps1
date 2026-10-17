param(
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-mirror-test'),
    [switch] $PrimaryRoute
)

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
function Invoke-NativeAo3Download { throw 'Native AO3 request was made.' }
function Download-FichubFile { throw 'FicHub was called for the AO3 mirror route.' }
function Invoke-FanFicFareDownload {
    param([string[]] $DownloadUrls, $Attempt, [string[]] $ExtraConfigPaths)
    if ($DownloadUrls.Count -ne 1 -or $DownloadUrls[0] -ne 'https://archiveofourown.org/works/123') {
        throw 'The mirror route changed the canonical AO3 work URL.'
    }
    $configText = Get-Content -LiteralPath $ExtraConfigPaths[0] -Raw
    foreach ($setting in @('use_archiveofourown_gay:true', 'use_archive_transformativeworks_org:false', 'use_browser_cache:false', 'open_pages_in_browser:false')) {
        if ($configText -notmatch ('(?m)^' + [regex]::Escape($setting) + '\r?$')) {
            throw "Mirror runtime config lacks $setting"
        }
    }
    Write-Host 'TEST_AO3_MIRROR_CONFIG_OK'
    return [pscustomobject]@{ ExitCode = 1; Stdout = 'URL(https://archiveofourown.org/works/123) Failed: synthetic'; Stderr = ''; TimedOut = $false }
}
'@
    if ($PrimaryRoute) {
        $stubs = $stubs.Replace("@('use_archiveofourown_gay:true', 'use_archive_transformativeworks_org:false', 'use_browser_cache:false', 'open_pages_in_browser:false')",
            "@('use_archiveofourown_gay:false', 'use_archive_transformativeworks_org:false', 'open_pages_in_browser:false')")
    }
    $script = $script.Replace($anchor, "$stubs`r`n$anchor")
    [IO.File]::WriteAllText((Join-Path $app 'Download AO3 with FanFicFare.ps1'), $script, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $source 'Download Clipboard Only.cmd') -Destination (Join-Path $app 'Download Clipboard Only.cmd')
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
        'retry_failed_urls=true',
        'prefer_native=true',
        'prefer_ao3_mirror=true',
        'open_after_download=false',
        '',
        '[updates]',
        'check_for_updates=false',
        '',
        '[accessibility]',
        'pause_on_error=false'
    ) -join "`r`n"
    if ($PrimaryRoute) {
        $settings = $settings.Replace('prefer_native=true', 'prefer_native=false').Replace('prefer_ao3_mirror=true', 'prefer_ao3_mirror=false')
    }
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $app 'user\failed-urls.txt'), 'https://archiveofourown.org/works/999', [Text.UTF8Encoding]::new($false))
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $output = & (Join-Path $app 'Download Clipboard Only.cmd') 'https://archiveofourown.org/works/123' 2>&1 | Out-String
    }
    finally {
        $env:TEMP = $oldTemp
    }
    if ($output -notmatch 'TEST_AO3_MIRROR_CONFIG_OK' -or $output -notmatch 'Skipping 1 queued URL') {
        throw "AO3 mirror or clipboard-only launcher was not used: $output"
    }
    $queued = Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt')
    if ('https://archiveofourown.org/works/123' -notin $queued) {
        throw 'Failed mirror work was not retained in the queue.'
    }
    if ('https://archiveofourown.org/works/999' -notin $queued) {
        throw 'Clipboard-only test removed a previously queued work.'
    }
    Write-Host "AO3 failure routing test passed (primary=$PrimaryRoute)."
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
