$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Downloader parse failed: $($errors[0].Message)" }

$helper = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-NativeAo3DownloadUrl' }, $true)
if (-not $helper) { throw 'Native AO3 URL helper is missing.' }
. ([scriptblock]::Create($helper.Extent.Text))

foreach ($format in @('epub', 'html', 'txt', 'mobi', 'pdf')) {
    $expected = "https://download.archiveofourown.org/downloads/91757466/work.$format"
    $actual = Get-NativeAo3DownloadUrl -WorkId '91757466' -Format $format
    if ($actual -cne $expected) { throw "Unexpected $format URL: $actual" }
}

$script = Get-Content -LiteralPath $source -Raw
$calls = [regex]::Matches($script, '\$downloadUrl = Get-NativeAo3DownloadUrl -WorkId \$workId -Format ')
if ($calls.Count -ne 3) { throw "Expected all three native download paths to use the helper; found $($calls.Count)." }
if ($script -match 'work\.[^"\r\n]*updated_at=') { throw 'A native AO3 URL still uses a fabricated update timestamp.' }
Write-Host 'Native AO3 URL construction test passed.'
