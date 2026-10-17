param([string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-mirror-config-test'))

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Downloader parse failed: $($errors[0].Message)" }
$helper = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-TemporaryFanFicFareRuntimeConfig' }, $true)
if (-not $helper) { throw 'FanFicFare runtime config function is missing.' }
. ([scriptblock]::Create($helper.Extent.Text))

$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
New-Item -ItemType Directory -Path $run -Force | Out-Null
$oldTemp = $env:TEMP
try {
    $env:TEMP = $run
    $stageDir = $run
    $userAgent = 'Test Agent'
    $preferAo3Mirror = $true
    foreach ($case in @(
        @{ Domain = 'archiveofourown.gay'; Gay = 'true'; TransformativeWorks = 'false' },
        @{ Domain = 'archive.transformativeworks.org'; Gay = 'false'; TransformativeWorks = 'true' }
    )) {
        $ao3MirrorDomain = $case.Domain
        $stamp = [guid]::NewGuid().ToString('N')
        $configPath = New-TemporaryFanFicFareRuntimeConfig
        $configText = Get-Content -LiteralPath $configPath -Raw
        foreach ($setting in @(
            "use_archiveofourown_gay:$($case.Gay)",
            "use_archive_transformativeworks_org:$($case.TransformativeWorks)",
            'use_browser_cache:false',
            'open_pages_in_browser:false'
        )) {
            if ($configText -notmatch ('(?m)^' + [regex]::Escape($setting) + '\r?$')) {
                throw "$($case.Domain) runtime config lacks $setting"
            }
        }
    }
    $preferAo3Mirror = $false
    $stamp = [guid]::NewGuid().ToString('N')
    $configText = Get-Content -LiteralPath (New-TemporaryFanFicFareRuntimeConfig) -Raw
    foreach ($setting in @('use_archiveofourown_gay:false', 'use_archive_transformativeworks_org:false', 'open_pages_in_browser:false')) {
        if ($configText -notmatch ('(?m)^' + [regex]::Escape($setting) + '\r?$')) {
            throw "Primary AO3 runtime config lacks $setting"
        }
    }
    if ($configText -match '(?m)^use_browser_cache:') {
        throw 'Primary AO3 route must preserve the user-configured passive browser cache setting.'
    }
    Write-Host 'Primary and alternate AO3 domain configs passed.'
}
finally {
    $env:TEMP = $oldTemp
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
