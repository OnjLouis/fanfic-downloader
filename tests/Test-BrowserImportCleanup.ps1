param(
    [Parameter(Mandatory = $true)][string] $FixtureEpub,
    [Parameter(Mandatory = $true)][string] $WorkUrl,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-cleanup-test')
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
New-Item -ItemType Directory -Path (Join-Path $app 'user'), $browser, $books, (Join-Path $run 'tmp') -Force | Out-Null
try {
    foreach ($name in @('Download AO3 with FanFicFare.ps1', 'Import Browser EPUBs.cmd', 'template.css', 'page_styles.css')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $app $name)
    }
    $browserCopy = Join-Path $browser 'matched.epub'
    $unmatchedCopy = Join-Path $browser 'unmatched.epub'
    Copy-Item -LiteralPath $FixtureEpub -Destination $browserCopy
    [IO.File]::WriteAllText($unmatchedCopy, 'Not an EPUB', [Text.Encoding]::ASCII)
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
        'delete_imported_browser_epubs=true',
        '',
        '[updates]',
        'check_for_updates=false',
        '',
        '[accessibility]',
        'pause_on_error=false'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings, [Text.UTF8Encoding]::new($false))
    $otherUrl = 'https://archiveofourown.org/works/123'
    [IO.File]::WriteAllLines((Join-Path $app 'user\failed-urls.txt'), [string[]]@($WorkUrl, $otherUrl), [Text.Encoding]::ASCII)

    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $output = & (Join-Path $app 'Import Browser EPUBs.cmd') $WorkUrl 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:TEMP = $oldTemp
    }
    if ($exitCode -ne 0) { throw "Browser import exited $exitCode`: $output" }
    if (@(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File).Count -ne 1) {
        throw 'Successfully imported EPUB was not saved.'
    }
    if (Test-Path -LiteralPath $browserCopy) {
        throw 'Successfully imported browser EPUB was not deleted.'
    }
    if (-not (Test-Path -LiteralPath $unmatchedCopy)) {
        throw 'Unmatched browser EPUB was deleted.'
    }
    $queued = @(Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt'))
    if ($WorkUrl -in $queued -or $otherUrl -notin $queued) {
        throw 'Browser import changed the wrong queued URL.'
    }

    Remove-Item -LiteralPath (Get-ChildItem -LiteralPath $books -Filter '*.epub' -File)[0].FullName
    Copy-Item -LiteralPath $FixtureEpub -Destination $browserCopy
    [IO.File]::WriteAllLines((Join-Path $app 'user\failed-urls.txt'), [string[]]@($WorkUrl, $otherUrl), [Text.Encoding]::ASCII)
    $scriptPath = Join-Path $app 'Download AO3 with FanFicFare.ps1'
    $script = [IO.File]::ReadAllText($scriptPath)
    $publishCall = '$publishedFile = Publish-PreparedFile -SourcePath $workPath -DestinationPath $finalPath'
    if ($script.IndexOf($publishCall, [StringComparison]::Ordinal) -lt 0) {
        throw 'Could not locate final publish call for failure test.'
    }
    $script = $script.Replace($publishCall, "throw 'Test publish failure'")
    [IO.File]::WriteAllText($scriptPath, $script, [Text.UTF8Encoding]::new($false))
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $failureOutput = & (Join-Path $app 'Import Browser EPUBs.cmd') $WorkUrl 2>&1 | Out-String
        $failureExitCode = $LASTEXITCODE
    }
    finally {
        $env:TEMP = $oldTemp
    }
    if ($failureExitCode -eq 0 -or $failureOutput -notmatch 'Test publish failure') {
        throw "Expected a publish failure, got exit code $failureExitCode`: $failureOutput"
    }
    if (-not (Test-Path -LiteralPath $browserCopy) -or
        @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File).Count -ne 0) {
        throw 'Failed publish deleted the browser source or saved an output EPUB.'
    }
    $queued = @(Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt'))
    if ($WorkUrl -notin $queued -or $otherUrl -notin $queued) {
        throw 'Failed publish removed a queued URL.'
    }
    Write-Host 'Browser EPUB cleanup passed: success deletes; failed publish retains.'
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
