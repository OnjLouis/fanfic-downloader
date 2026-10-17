param(
    [Parameter(Mandatory = $true)][string] $FanFictionFixture,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-ffn-chapters-test')
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
    $browserCopy = Join-Path $browser '48-chapters.epub'
    Copy-Item -LiteralPath $FanFictionFixture -Destination $browserCopy
    $url = 'https://www.fanfiction.net/s/13985352/49/Arch-Mage-the-Path-of-Magic'
    [IO.File]::WriteAllLines((Join-Path $app 'user\failed-urls.txt'), [string[]]@($url), [Text.Encoding]::ASCII)
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
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $output = & (Join-Path $app 'Import Browser EPUBs.cmd') 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally { $env:TEMP = $oldTemp }
    if ($exitCode -ne 4 -or -not (Test-Path -LiteralPath $browserCopy) -or
        @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File).Count -ne 0 -or
        $url -notin @(Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt'))) {
        throw "A 48-chapter EPUB satisfied a queued chapter 49 URL: $output"
    }
    Write-Host 'Browser FanFiction.net chapter guard passed.'
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
