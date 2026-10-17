param(
    [Parameter(Mandatory = $true)][string] $FixtureEpub,
    [Parameter(Mandatory = $true)][string] $WorkUrl,
    [Parameter(Mandatory = $true)][int] $KnownChapterCount,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-import-test')
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
$app = Join-Path $run 'app'
$browser = Join-Path $run 'browser'
$books = Join-Path $run 'books'
New-Item -ItemType Directory -Path (Join-Path $app 'user'), $browser, $books -Force | Out-Null
try {
    foreach ($name in @('Download AO3 with FanFicFare.ps1', 'Import Browser EPUBs.cmd', 'template.css', 'page_styles.css')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $app $name)
    }
    Copy-Item -LiteralPath $FixtureEpub -Destination (Join-Path $browser 'fixture.epub')
    $settings = @(
        '[paths]',
        "output_dir=$books",
        "log_dir=$(Join-Path $run 'logs')",
        "browser_epub_folder=$browser",
        'fanficfare_exe=missing.exe',
        '',
        '[download]',
        'format=epub',
        'open_after_download=false',
        'read_clipboard=false',
        'retry_failed_urls=true',
        '',
        '[updates]',
        'check_for_updates=false',
        '',
        '[accessibility]',
        'pause_on_error=false'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings, [Text.UTF8Encoding]::new($false))

    $missingUrl = 'https://archiveofourown.org/works/123'
    $queuedUrl = 'https://archiveofourown.org/works/456'
    if ($WorkUrl -notmatch '/works/(?<id>\d+)') { throw 'Test URL has no AO3 work ID.' }
    $workId = $Matches['id']
    $chapterHistory = @{ "ao3:$workId" = $KnownChapterCount } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $app 'user\chapter-history.json'), $chapterHistory, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $app 'user\failed-urls.txt'), [string[]]@($WorkUrl, $queuedUrl), [Text.Encoding]::ASCII)
    $output = & (Join-Path $app 'Import Browser EPUBs.cmd') $WorkUrl $missingUrl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Import mode exited $LASTEXITCODE`: $output" }
    if ($output -match 'Trying AO3 native|Checking FicHub|trying FanFicFare backup') {
        throw "Import mode attempted a network download route: $output"
    }
    $saved = @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File)
    if ($saved.Count -ne 1) { throw "Expected one saved EPUB, found $($saved.Count)." }
    if (-not (Test-Path -LiteralPath (Join-Path $browser 'fixture.epub'))) {
        throw 'Browser source EPUB was moved or deleted.'
    }
    $queued = Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt')
    if ($missingUrl -notin $queued -or $queuedUrl -notin $queued -or $WorkUrl -in $queued) {
        throw 'Import mode did not retain only the missing URLs.'
    }
    $savedHash = (Get-FileHash -LiteralPath $saved[0].FullName).Hash
    $repeatOutput = & (Join-Path $app 'Import Browser EPUBs.cmd') $WorkUrl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 4 -or $repeatOutput -notmatch 'No new matching EPUB from a supported site' -or
        (Get-FileHash -LiteralPath $saved[0].FullName).Hash -ne $savedHash) {
        throw 'Import mode replaced or reopened an unchanged saved EPUB.'
    }
    Remove-Item -LiteralPath $saved[0].FullName
    $newerHistory = @{ "ao3:$workId" = ($KnownChapterCount + 1) } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $app 'user\chapter-history.json'), $newerHistory, [Text.UTF8Encoding]::new($false))
    $olderOutput = & (Join-Path $app 'Import Browser EPUBs.cmd') $WorkUrl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 4 -or $olderOutput -notmatch 'No new matching EPUB from a supported site') {
        throw 'Import mode accepted a browser EPUB with fewer chapters than known history.'
    }
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings.Replace("browser_epub_folder=$browser", 'browser_epub_folder='), [Text.UTF8Encoding]::new($false))
    $noFolderOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'Download AO3 with FanFicFare.ps1') -BrowserImportsOnly -SkipUpdateCheck $WorkUrl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 2 -or $noFolderOutput -notmatch 'needs EPUB output and an existing browser_epub_folder') {
        throw "Expected a clear missing-folder error, got: $noFolderOutput"
    }
    Write-Host "Browser import mode passed: $($saved[0].Name)"
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
