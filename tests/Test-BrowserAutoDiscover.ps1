param(
    [Parameter(Mandatory = $true)][string] $Ao3Fixture,
    [Parameter(Mandatory = $true)][string] $FanFictionFixture,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-discovery-test')
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
    $ao3Copy = Join-Path $browser 'ao3.epub'
    $fanFictionCopy = Join-Path $browser 'fanfiction.epub'
    $unrelated = Join-Path $browser 'kobo.epub'
    Copy-Item -LiteralPath $Ao3Fixture -Destination $ao3Copy
    Copy-Item -LiteralPath $FanFictionFixture -Destination $fanFictionCopy
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($unrelated, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('chapter.xhtml')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write('<html><body><a href="https://archiveofourown.org/works/91757466">Related reading</a></body></html>') } finally { $writer.Dispose() }
    }
    finally { $zip.Dispose() }
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
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = 'powershell.exe'
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $app 'Download AO3 with FanFicFare.ps1') + '" -BrowserImportsOnly -SkipUpdateCheck'
        $info.WorkingDirectory = $app
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            $process.Kill()
            throw 'Browser auto-discovery test timed out.'
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        $process.Dispose()
    }
    finally { $env:TEMP = $oldTemp }
    if ($exitCode -ne 0) {
        $diagnostic = Get-Content -LiteralPath (Join-Path $run 'logs\downloader.log') -Raw
        throw "Browser auto-discovery exited $exitCode`: $output`n$diagnostic"
    }
    if (@(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File).Count -ne 2) {
        throw "Expected AO3 and FanFiction.net output EPUBs: $output"
    }
    if ((Test-Path -LiteralPath $ao3Copy) -or (Test-Path -LiteralPath $fanFictionCopy)) {
        throw 'A successfully imported browser EPUB was not deleted.'
    }
    if (-not (Test-Path -LiteralPath $unrelated)) {
        throw 'An unrelated EPUB was deleted.'
    }
    if (Test-Path -LiteralPath (Join-Path $app 'user\failed-urls.txt')) {
        $queued = @(Get-Content -LiteralPath (Join-Path $app 'user\failed-urls.txt') | Where-Object { $_.Trim() })
        if ($queued.Count -ne 0) { throw 'Auto-discovered EPUBs were queued as failures.' }
    }

    Copy-Item -LiteralPath $FanFictionFixture -Destination $fanFictionCopy
    $savedHashes = @{}
    foreach ($book in @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File)) {
        $savedHashes[$book.Name] = (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash
    }
    $scriptPath = Join-Path $app 'Download AO3 with FanFicFare.ps1'
    $script = [IO.File]::ReadAllText($scriptPath)
    $anchor = '$providedUrls = @($urls)'
    if ($script.IndexOf($anchor, [StringComparison]::Ordinal) -lt 0) {
        throw 'Could not locate URL selection for the offline network guard.'
    }
    $script = $script.Replace($anchor, "function Download-FichubFile { throw 'TEST_NETWORK_CALLED' }`r`n$anchor")
    [IO.File]::WriteAllText($scriptPath, $script, [Text.UTF8Encoding]::new($false))
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -SkipUpdateCheck'
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = Join-Path $run 'tmp'
        $process = [Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            $process.Kill()
            throw 'Normal-launcher no-network test timed out.'
        }
        $repeatOutput = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $repeatExitCode = $process.ExitCode
        $process.Dispose()
    }
    finally { $env:TEMP = $oldTemp }
    if ($repeatExitCode -ne 0 -or $repeatOutput -match 'TEST_NETWORK_CALLED' -or
        $repeatOutput -notmatch 'No newer supported browser EPUBs were found') {
        throw "Normal launcher retried an unchanged browser EPUB: $repeatOutput"
    }
    if (-not (Test-Path -LiteralPath $fanFictionCopy) -or -not (Test-Path -LiteralPath $unrelated)) {
        throw 'Normal launcher removed an unchanged or unrelated EPUB.'
    }
    foreach ($book in @(Get-ChildItem -LiteralPath $books -Filter '*.epub' -File)) {
        if ($savedHashes[$book.Name] -ne (Get-FileHash -LiteralPath $book.FullName -Algorithm SHA256).Hash) {
            throw 'Normal launcher replaced an unchanged saved book.'
        }
    }
    Write-Host 'Browser auto-discovery passed; unrelated and unchanged EPUBs stayed untouched.'
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
