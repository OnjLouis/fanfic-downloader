param(
    [Parameter(Mandatory = $true)][string] $Ao3Fixture,
    [Parameter(Mandatory = $true)][string] $FanFictionFixture,
    [string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-origin-test')
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Downloader parse failed: $($errors[0].Message)" }
foreach ($name in @('Convert-ToDownloadUrl', 'Get-SupportedBrowserEpubOriginUrl')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing browser origin function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
New-Item -ItemType Directory -Path $run -Force | Out-Null
try {
    if ((Get-SupportedBrowserEpubOriginUrl -EpubPath $Ao3Fixture) -ne 'https://archiveofourown.org/works/91757466') {
        throw 'AO3 front-matter attribution was not recognized.'
    }
    $fanFictionUrl = 'https://www.fanfiction.net/s/13985352/1/Arch-Mage-the-Path-of-Magic'
    if ((Get-SupportedBrowserEpubOriginUrl -EpubPath $FanFictionFixture) -ne $fanFictionUrl) {
        throw 'FicHub FanFiction.net attribution was not recognized.'
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fictionPressCopy = Join-Path $run 'fictionpress.epub'
    Copy-Item -LiteralPath $FanFictionFixture -Destination $fictionPressCopy
    $zip = [IO.Compression.ZipFile]::Open($fictionPressCopy, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -match '(?i)(^|/)introduction\.xhtml$' } | Select-Object -First 1
        if (-not $entry) { throw 'FanFiction fixture has no introduction page.' }
        $name = $entry.FullName
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $html = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $entry.Delete()
        $replacement = $zip.CreateEntry($name)
        $writer = [IO.StreamWriter]::new($replacement.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write($html.Replace('www.fanfiction.net', 'www.fictionpress.com')) } finally { $writer.Dispose() }
    }
    finally { $zip.Dispose() }
    $fictionPressUrl = $fanFictionUrl.Replace('www.fanfiction.net', 'www.fictionpress.com')
    $foundFictionPressUrl = Get-SupportedBrowserEpubOriginUrl -EpubPath $fictionPressCopy
    if ($foundFictionPressUrl -ne $fictionPressUrl) {
        throw "FicHub FictionPress attribution was not recognized: $foundFictionPressUrl"
    }

    $unrelated = Join-Path $run 'unrelated.epub'
    $zip = [IO.Compression.ZipFile]::Open($unrelated, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('chapter.xhtml')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write('<html><body><p>See also https://archiveofourown.org/works/91757466</p></body></html>') } finally { $writer.Dispose() }
    }
    finally { $zip.Dispose() }
    if (Get-SupportedBrowserEpubOriginUrl -EpubPath $unrelated) {
        throw 'An incidental AO3 link was mistaken for source attribution.'
    }
    Write-Host 'AO3, FanFiction.net, FictionPress, and unrelated EPUB origin checks passed.'
}
finally {
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
