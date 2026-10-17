param([string] $ScratchParent)

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Downloader parse failed.' }
foreach ($name in @('Invoke-FanFicFareDownload', 'Get-StoryDisplayName', 'Convert-ToDownloadUrl', 'Test-FanFicFareLoginFailure')) {
    $helper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    . ([scriptblock]::Create($helper.Extent.Text))
}
if (-not (Get-Command Invoke-FanFicFareDownload).ScriptBlock.ToString().Contains('Invoke-FanFicFareDownloadProcess')) {
    throw 'Story isolation is missing: the batch still uses one subprocess.'
}
$script:calls = @()
$script:statuses = @()
function Write-Status { param([string] $Message) $script:statuses += $Message }
function Write-Log { param([string] $Message) }
function Invoke-FanFicFareDownloadProcess {
    param([string[]] $DownloadUrls, [string] $Attempt, [string[]] $ExtraConfigPaths)
    if ($DownloadUrls.Count -ne 1) { throw 'A subprocess received more than one story.' }
    $script:calls += $DownloadUrls[0]
    $id = $DownloadUrls[0].Split('/')[-1]
    switch ($id) {
        '1' { return [pscustomobject]@{ExitCode=1; Stdout=''; Stderr='525 Server Error'; TimedOut=$false} }
        '2' { return [pscustomobject]@{ExitCode=0; Stdout='Downloaded'; Stderr=''; TimedOut=$false} }
        '3' { throw 'Synthetic subprocess launch failure' }
        '4' { return [pscustomobject]@{ExitCode=0; Stdout='Login Failed on non-interactive process. Set username and password in personal.ini.'; Stderr=''; TimedOut=$false} }
        '5' { return [pscustomobject]@{ExitCode=124; Stdout=''; Stderr=''; TimedOut=$true} }
    }
}
$urls = @(1..5 | ForEach-Object { "https://archiveofourown.org/works/$_" })
$result = Invoke-FanFicFareDownload -DownloadUrls $urls -Attempt '1' -ExtraConfigPaths @('synthetic.ini')
if ($script:calls.Count -ne 5 -or ($script:calls -join ',') -ne ($urls -join ',')) { throw 'A failed story prevented a later attempt.' }
if ($result.ExitCode -eq 0 -or -not $result.TimedOut) { throw 'Partial batch failure was reported as success.' }
foreach ($id in @(1, 3, 4, 5)) {
    if ($result.Stdout -notmatch [regex]::Escape("URL(https://archiveofourown.org/works/$id) Failed")) { throw "Failure was not attributed to work $id." }
}
if ($result.Stdout -match [regex]::Escape('URL(https://archiveofourown.org/works/2) Failed')) { throw 'Successful work was attributed as failed.' }
if (($script:statuses -join "`n") -match 'https?://') { throw 'Batch progress displayed full URLs.' }
Write-Host 'Batch isolation passed: 525, launch failure, login failure and timeout did not skip later stories.'
if ($ScratchParent) {
    $base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
    $run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
    if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid scratch path.' }
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    $oldTemp = $env:TEMP
    try {
        $env:TEMP = $run
        $fff = Join-Path $run 'Local Fake Downloader.cmd'
        $outDir = $run
        $config = Join-Path $run 'empty.ini'
        $stamp = [guid]::NewGuid().ToString('N')
        $downloadFormat = 'epub'
        $logFile = Join-Path $run 'process.log'
        $showWaitMessages = $false
        [IO.File]::WriteAllText($config, '')
        $fake = @'
@echo off
for %%A in (%*) do (
  if "%%~A"=="https://archiveofourown.org/works/1" (
    echo 525 Server Error
    exit /b 1
  )
)
echo Local fake downloader completed
exit /b 0
'@
        [IO.File]::WriteAllText($fff, $fake)
        foreach ($name in @('Invoke-FanFicFareDownloadProcess', 'Quote-CmdArgument')) {
            $helper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($helper.Extent.Text))
        }
        $result = Invoke-FanFicFareDownload -DownloadUrls $urls[0..1] -Attempt 'real-process-test'
        if ($result.ExitCode -eq 0 -or $result.Stdout -notmatch 'Local fake downloader completed' -or
            $result.Stdout -notmatch '525 Server Error') { throw 'Real subprocess isolation did not preserve both outcomes.' }
        Write-Host 'Local command subprocess check passed; no site requests were made.'
    }
    finally {
        $env:TEMP = $oldTemp
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
    }
}
