param(
    [Parameter(Mandatory = $true)][string] $FixtureEpub,
    [string] $AlreadyDownloadedFixture,
    [Parameter(Mandatory = $true)][string] $ScratchParent
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$base = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$run = [IO.Path]::GetFullPath((Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $run.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid scratch path.' }
$oldTemp = $env:TEMP
$oldCase = $env:LOGIN_TEST_CASE
$oldFixture = $env:LOGIN_TEST_FIXTURE
$oldPublicFixture = $env:LOGIN_TEST_PUBLIC_FIXTURE
try {
    $cases = @('success', 'cancel', 'failed-retry', 'unattended')
    if ($AlreadyDownloadedFixture) { $cases += @('mixed-success', 'mixed-cancel', 'mixed-failed-retry') }
    foreach ($case in $cases) {
        $app = Join-Path $run $case
        New-Item -ItemType Directory -Path (Join-Path $app 'user'), (Join-Path $app 'tmp') -Force | Out-Null
        $script = Get-Content -LiteralPath (Join-Path $source 'Download AO3 with FanFicFare.ps1') -Raw
        $anchor = '$providedUrls = @($urls)'
        $stubs = @'
function Test-CanPrompt { return $env:LOGIN_TEST_CASE -ne 'unattended' }
function Read-Host {
    param([string] $Prompt, [switch] $AsSecureString)
    if ($env:LOGIN_TEST_CASE -eq 'unattended') { throw 'UNATTENDED_PROMPT' }
    if ($Prompt -eq 'AO3 username') {
        Write-Status 'TEST_USERNAME_PROMPT'
        if ($env:LOGIN_TEST_CASE -in @('cancel', 'mixed-cancel')) { return '' }
        return 'SyntheticUserNotARealAccount'
    }
    if ($Prompt -eq 'AO3 password' -and $AsSecureString) {
        Write-Status 'TEST_MASKED_PASSWORD_PROMPT'
        return ConvertTo-SecureString 'SyntheticPasswordNotARealSecret' -AsPlainText -Force
    }
    throw "Unexpected prompt: $Prompt"
}
function Invoke-NativeAo3Download { throw 'NETWORK_CALLED' }
function Download-FichubFile { throw 'NETWORK_CALLED' }
function Start-Process {
    [CmdletBinding()]
    param([string] $FilePath, [string[]] $ArgumentList)
    if ($FilePath -notlike '*reader.exe' -or -not (Test-Path -LiteralPath $ArgumentList[0])) { throw 'Reader received an invalid saved file.' }
    [IO.File]::AppendAllText((Join-Path $outDir 'opened.txt'), [IO.Path]::GetFileName($ArgumentList[0]) + "`n")
}
function Invoke-FanFicFareDownload {
    param([string[]] $DownloadUrls, [string] $Attempt, [string[]] $ExtraConfigPaths)
    $message = 'Login Failed on non-interactive process. Set username and password in personal.ini.'
    if ($Attempt -ne 'login' -and $env:LOGIN_TEST_CASE -like 'mixed-*') {
        Copy-Item -LiteralPath $env:LOGIN_TEST_PUBLIC_FIXTURE -Destination (Join-Path $stageDir 'Public.epub')
    }
    if ($Attempt -eq 'login') {
        if ($env:LOGIN_TEST_CASE -like 'mixed-*' -and
            ($DownloadUrls.Count -ne 1 -or $DownloadUrls[0] -ne 'https://archiveofourown.org/works/92066671')) {
            throw 'The login retry unnecessarily retried an already retrieved story.'
        }
        Write-Status 'TEST_LOGIN_RETRY'
        $script:TestLoginPath = $ExtraConfigPaths[-1]
        $text = Get-Content -LiteralPath $script:TestLoginPath -Raw
        if ($text -notmatch 'username:SyntheticUserNotARealAccount' -or $text -notmatch 'password:SyntheticPasswordNotARealSecret') {
            throw 'Credentials were not supplied to the login retry.'
        }
        if ($env:LOGIN_TEST_CASE -in @('success', 'mixed-success')) {
            Copy-Item -LiteralPath $env:LOGIN_TEST_FIXTURE -Destination (Join-Path $stageDir 'Fixture.epub')
            $message = ''
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Stdout = $message; Stderr = ''; TimedOut = $false }
}
'@
        if (-not $script.Contains($anchor)) { throw 'URL collection anchor not found.' }
        [IO.File]::WriteAllText((Join-Path $app 'Download.ps1'), $script.Replace($anchor, "$stubs`r`n$anchor"))
        [IO.File]::WriteAllText((Join-Path $app 'dummy.exe'), '')
        $settings = @(
            '[paths]', "output_dir=$app\books", "log_dir=$app\logs", 'fanficfare_exe=dummy.exe', "reader_path=$app\reader.exe",
            '[download]', 'read_clipboard=false', 'prefer_native=false', 'prefer_ao3_mirror=false',
            'open_after_download=false', '[accessibility]', 'pause_on_error=false'
        ) -join "`r`n"
        if ($case -eq 'unattended') { $settings = $settings.Replace('pause_on_error=false', 'pause_on_error=true') }
        if ($case -like 'mixed-*') { $settings = $settings.Replace('open_after_download=false', 'open_after_download=true') }
        [IO.File]::WriteAllText((Join-Path $app 'user\downloader.ini'), $settings)
        $queue = Join-Path $app 'user\failed-urls.txt'
        [IO.File]::WriteAllLines($queue, [string[]]@('https://archiveofourown.org/works/92066671', 'https://archiveofourown.org/works/999'))
        if ($case -like 'mixed-*') { [IO.File]::AppendAllText($queue, "https://archiveofourown.org/works/36465463`r`n") }
        $env:TEMP = Join-Path $app 'tmp'
        $env:LOGIN_TEST_CASE = $case
        $env:LOGIN_TEST_FIXTURE = $FixtureEpub
        $env:LOGIN_TEST_PUBLIC_FIXTURE = $AlreadyDownloadedFixture
        $inputUrls = @('https://archiveofourown.org/works/92066671')
        if ($case -like 'mixed-*') { $inputUrls += 'https://archiveofourown.org/works/36465463' }
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'Download.ps1') -SkipUpdateCheck -SkipFailedQueue @inputUrls 2>&1 | Out-String
        $code = $LASTEXITCODE
        $queued = @(Get-Content -LiteralPath $queue)
        if ($case -in @('success', 'mixed-success')) {
            $expectedBooks = if ($case -eq 'mixed-success') { 2 } else { 1 }
            if ($code -ne 0 -or $output -notmatch 'AO3 login retry succeeded' -or
                'https://archiveofourown.org/works/92066671' -in $queued -or
                @(Get-ChildItem -LiteralPath (Join-Path $app 'books') -Filter '*.epub').Count -ne $expectedBooks) {
                throw "Login success case failed: $output"
            }
        }
        else {
            if (($case -notlike 'mixed-*' -and $code -eq 0) -or 'https://archiveofourown.org/works/92066671' -notin $queued) {
                throw "$case cleared the failed work or reported success: $output"
            }
        }
        if ($case -like 'mixed-*' -and
            ('https://archiveofourown.org/works/36465463' -in $queued -or
            @(Get-ChildItem -LiteralPath (Join-Path $app 'books') -Filter 'Public.epub').Count -ne 1)) {
            throw "A later login failure prevented a successful story from being saved or cleared: $output"
        }
        if ($case -like 'mixed-*') {
            $opened = @(Get-Content -LiteralPath (Join-Path $app 'books\opened.txt'))
            $expectedOpens = if ($case -eq 'mixed-success') { 2 } else { 1 }
            if ($opened.Count -ne $expectedOpens -or 'Public.epub' -notin $opened) {
                throw 'Successful books were not opened after a mixed batch.'
            }
        }
        if ('https://archiveofourown.org/works/999' -notin $queued) { throw 'Unrelated queue entry was removed.' }
        if ($case -eq 'unattended') {
            if ($output -match 'TEST_USERNAME_PROMPT|UNATTENDED_PROMPT|TEST_LOGIN_RETRY') { throw 'Unattended login attempted a prompt.' }
        }
        elseif ($output -notmatch 'TEST_USERNAME_PROMPT') { throw "Missing username prompt: $output" }
        if ($case -in @('success', 'failed-retry', 'mixed-success', 'mixed-failed-retry') -and $output -notmatch 'TEST_MASKED_PASSWORD_PROMPT') {
            throw 'Password prompt was not masked.'
        }
        if ($case -in @('failed-retry', 'mixed-failed-retry') -and $output -match 'AO3 login retry succeeded') {
            throw 'FanFicFare exit code zero hid a failed login retry.'
        }
        if ($output -match 'SyntheticUserNotARealAccount|SyntheticPasswordNotARealSecret') { throw 'Console exposed credentials.' }
        $log = Join-Path $app 'logs\downloader.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Content -LiteralPath $log -Raw) -match 'SyntheticUserNotARealAccount|SyntheticPasswordNotARealSecret') {
            throw 'Log exposed credentials.'
        }
        if (@(Get-ChildItem -LiteralPath (Join-Path $app 'tmp') -Filter '*login*.ini' -File -Recurse).Count -gt 0) { throw 'Temporary login config remained.' }
        Write-Host "AO3 login case passed: $case"
    }
}
finally {
    $env:TEMP = $oldTemp
    $env:LOGIN_TEST_CASE = $oldCase
    $env:LOGIN_TEST_FIXTURE = $oldFixture
    $env:LOGIN_TEST_PUBLIC_FIXTURE = $oldPublicFixture
    Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
