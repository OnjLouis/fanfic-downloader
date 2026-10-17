param(
    [Parameter(Mandatory = $true)][string] $FixtureEpub,
    [Parameter(Mandatory = $true)][string] $WorkUrl,
    [switch] $PrimaryRoute,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-mirror-success-test')
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
$app = Join-Path $run 'app'
$books = Join-Path $run 'books'
New-Item -ItemType Directory -Path (Join-Path $app 'user'), $books, (Join-Path $run 'tmp') -Force | Out-Null
try {
    $script = Get-Content -LiteralPath (Join-Path $source 'Download AO3 with FanFicFare.ps1') -Raw
    $anchor = '$providedUrls = @($urls)'
    if ($script.IndexOf($anchor, [StringComparison]::Ordinal) -lt 0) { throw 'Could not locate URL selection.' }
    $stubs = @'
function Invoke-NativeAo3Download { throw 'Native AO3 request was made.' }
function Download-FichubFile { throw 'FicHub was called for the AO3 mirror route.' }
function Invoke-FanFicFareDownload {
    param([string[]] $DownloadUrls, $Attempt, [string[]] $ExtraConfigPaths)
    if ($DownloadUrls.Count -ne 1 -or $DownloadUrls[0] -ne $env:MIRROR_TEST_URL) {
        throw 'The mirror route did not receive the requested work URL alone.'
    }
    $configText = Get-Content -LiteralPath $ExtraConfigPaths[0] -Raw
    foreach ($setting in @('use_archiveofourown_gay:true', 'use_browser_cache:false', 'open_pages_in_browser:false')) {
        if ($configText -notmatch ('(?m)^' + [regex]::Escape($setting) + '\r?$')) {
            throw "Mirror runtime config lacks $setting"
        }
    }
    Copy-Item -LiteralPath $env:MIRROR_TEST_FIXTURE -Destination (Join-Path $stageDir 'Fixture.epub')
    Write-Host 'TEST_AO3_MIRROR_EPUB_READY'
    return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = ''; TimedOut = $false }
}
'@
    if ($PrimaryRoute) {
        $stubs = $stubs.Replace("@('use_archiveofourown_gay:true', 'use_browser_cache:false', 'open_pages_in_browser:false')",
            "@('use_archiveofourown_gay:false', 'use_archive_transformativeworks_org:false', 'open_pages_in_browser:false')")
    }
    $script = $script.Replace($anchor, "$stubs`r`n$anchor")
    [IO.File]::WriteAllText((Join-Path $app 'Download AO3 with FanFicFare.ps1'), $script, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $source 'Download Clipboard Only.cmd') -Destination (Join-Path $app 'Download Clipboard Only.cmd')
    foreach ($name in @('template.css', 'page_styles.css')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $app $name)
    }
    [IO.File]::WriteAllText((Join-Path $app 'dummy.exe'), '', [Text.UTF8Encoding]::new($false))
    $settings = @(
        '[paths]',
        "output_dir=$books",
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
    [IO.File]::WriteAllLines((Join-Path $app 'user\failed-urls.txt'), [string[]]@($WorkUrl, 'https://archiveofourown.org/works/999'), [Text.Encoding]::ASCII)
    $existingName = 'Previously Read Holly Potter.epub'
    Copy-Item -LiteralPath $FixtureEpub -Destination (Join-Path $books $existingName)

    $oldTemp = $env:TEMP
    $oldFixture = $env:MIRROR_TEST_FIXTURE
    $oldUrl = $env:MIRROR_TEST_URL
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $env:MIRROR_TEST_FIXTURE = $FixtureEpub
        $env:MIRROR_TEST_URL = $WorkUrl
        $output = & (Join-Path $app 'Download Clipboard Only.cmd') $WorkUrl 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:TEMP = $oldTemp
        $env:MIRROR_TEST_FIXTURE = $oldFixture
        $env:MIRROR_TEST_URL = $oldUrl
    }
    if ($exitCode -ne 0 -or $output -notmatch 'TEST_AO3_MIRROR_EPUB_READY') {
        throw "Mirror success path failed with exit code $exitCode`: $output"
    }
    $saved = @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File)
    if ($saved.Count -ne 1 -or $saved[0].Name -ne $existingName) {
        throw "Mirror download changed the existing book filename: $(@($saved.Name) -join ', ')"
    }
    $queued = @(Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt'))
    if ($WorkUrl -in $queued -or 'https://archiveofourown.org/works/999' -notin $queued) {
        throw 'Successful mirror download did not remove only its own failed URL.'
    }
    Write-Host "AO3 success path passed (primary=$PrimaryRoute): $($saved[0].Name)"
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
