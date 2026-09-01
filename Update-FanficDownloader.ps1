[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $LibraryOnly,
    [switch] $CheckOnly,
    [switch] $Install,
    [switch] $ForceCheck,
    [switch] $NonInteractive,
    [switch] $Quiet,
    [string] $AppDirectory = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProductId = "OnjLouis.FanficDownloader"
$ReleaseApiUrl = "https://api.github.com/repos/OnjLouis/fanfic-downloader/releases/latest"
$UpdateCheckHours = 24
$MaximumMetadataBytes = 1MB
$MaximumPackageBytes = 20MB
$MaximumExtractedBytes = 30MB
$MaximumArchiveEntries = 100
$RetainedBackups = 2
$RetainedLogs = 10
$TrustedPublicKeyXml = @'
<RSAKeyValue><Modulus>ksgLIbZif39/IxO5HhD4ZtESlhHHAkEzo5B/sfoa0fk74waCbCqwAXP0d2z3LJ7oe+qg9Nd+HH0m2RHS50berb8FcST/CqC+RMmnOxgkP7TOWeuK9DPpjjRj8Y+yfsDGfeepW+l531fgIK5JhinH7q/fFDt4H/w2Ag7afsOkQxC44CmP9/n5ecAWbvBmy+iGid3BX+V5T44yBsUDJB0QipemQ39StwQU/8edActbkuVdf3R4EF8Qz0fb6snXZSx3XHuVqz9W/TKu6YmwVohx7b73S1ZL74MyRxFCBUEDXFpKRmUu8H+E1fwGagwyl5t7MJ/vc0ICEhWUb+OQcruf5lD0IO1VonC8//F3Wn9XZdmN8t7SPxyyLlOxijvQ8aQVWLL8K/9S+0/3jYEA34H1RKYcT1cM+2UbODOHlIAW2ZRrEUIBefBsvkV9ubM86tKYNv7iUwYL9w7idO/ZmkrIbc0FcjSGV65jYFCvKMMDbuQUQrOp9wluBPW8dM8Daeu1</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>
'@

if ([string]::IsNullOrWhiteSpace($AppDirectory)) {
    $AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$ResolvedAppDirectory = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\')
$UserDirectory = Join-Path $ResolvedAppDirectory "user"
$UpdateDirectory = Join-Path $UserDirectory "updates"
$UpdateLogDirectory = Join-Path $UpdateDirectory "logs"
$UpdateStatePath = Join-Path $UpdateDirectory "state.json"
$UpdateLogPath = $null

function Write-UpdateStatus {
    param(
        [string] $Message,
        [switch] $Always
    )

    if (-not $Quiet -or $Always) {
        Write-Host $Message
    }
    if ($UpdateLogPath) {
        $Message | Out-File -LiteralPath $UpdateLogPath -Append -Encoding utf8
    }
}

function Convert-ToVersion {
    param([string] $Value)

    $clean = $Value.Trim().TrimStart('v', 'V')
    if ($clean -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid release version: $Value"
    }
    return [version]$clean
}

function Get-InstalledVersion {
    param([string] $Directory = $ResolvedAppDirectory)

    $path = Join-Path $Directory "version.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return [version]"0.0.0"
    }
    $metadata = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([string]$metadata.product -ne $ProductId) {
        throw "The installed version metadata belongs to a different program."
    }
    return Convert-ToVersion ([string]$metadata.version)
}

function Get-HttpsBytes {
    param(
        [string] $Url,
        [long] $MaximumBytes
    )

    $uri = [uri]$Url
    if ($uri.Scheme -ne "https") {
        throw "The update service supplied a non-HTTPS address."
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("OnjLouis-FanficDownloader-Updater/1.0")
    $response = $null
    $stream = $null
    $memory = [System.IO.MemoryStream]::new()
    try {
        $response = $client.GetAsync($uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        if ($response.RequestMessage.RequestUri.Scheme -ne "https") {
            throw "The update download redirected outside HTTPS."
        }
        $declaredLength = $response.Content.Headers.ContentLength
        if ($declaredLength -and $declaredLength -gt $MaximumBytes) {
            throw "The update download was unexpectedly large."
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $MaximumBytes) {
                throw "The update download exceeded its size limit."
            }
            $memory.Write($buffer, 0, $read)
        }
        return $memory.ToArray()
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $memory.Dispose()
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ReleaseAsset {
    param(
        [object] $Release,
        [string] $Name
    )

    $matches = @($Release.assets | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -ne 1) {
        throw "Release asset is missing or duplicated: $Name"
    }
    $url = [string]$matches[0].browser_download_url
    if (-not $url.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Release asset did not use HTTPS: $Name"
    }
    return [pscustomobject]@{ Name = $Name; Url = $url }
}

function Get-LatestRelease {
    $releaseBytes = Get-HttpsBytes -Url $ReleaseApiUrl -MaximumBytes $MaximumMetadataBytes
    $release = [System.Text.Encoding]::UTF8.GetString($releaseBytes) | ConvertFrom-Json
    if ([bool]$release.draft -or [bool]$release.prerelease) {
        throw "GitHub returned an unfinished release."
    }
    $version = Convert-ToVersion ([string]$release.tag_name)
    $versionText = $version.ToString(3)
    $packageName = "FanficDownloader-$versionText.zip"
    $manifestName = "FanficDownloader-$versionText.manifest.json"
    $signatureName = "FanficDownloader-$versionText.manifest.sig"
    return [pscustomobject]@{
        Version = $version
        VersionText = $versionText
        PageUrl = [string]$release.html_url
        Package = Get-ReleaseAsset -Release $release -Name $packageName
        Manifest = Get-ReleaseAsset -Release $release -Name $manifestName
        Signature = Get-ReleaseAsset -Release $release -Name $signatureName
    }
}

function Read-UpdateState {
    if (-not (Test-Path -LiteralPath $UpdateStatePath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $UpdateStatePath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-UpdateState {
    param(
        [version] $LatestVersion,
        [string] $PageUrl = ""
    )

    New-Item -ItemType Directory -Force -Path $UpdateDirectory | Out-Null
    $state = [ordered]@{
        lastCheckedUtc = [DateTime]::UtcNow.ToString("o")
        latestVersion = $LatestVersion.ToString(3)
        pageUrl = $PageUrl
    }
    $temporary = "$UpdateStatePath.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $UpdateStatePath -Force
}

function Get-CachedLatestVersion {
    if ($ForceCheck) {
        return $null
    }
    $state = Read-UpdateState
    if (-not $state -or [string]::IsNullOrWhiteSpace([string]$state.lastCheckedUtc)) {
        return $null
    }
    $checkedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$state.lastCheckedUtc, [ref]$checkedAt)) {
        return $null
    }
    if ([DateTime]::UtcNow - $checkedAt.ToUniversalTime() -ge [TimeSpan]::FromHours($UpdateCheckHours)) {
        return $null
    }
    try {
        return Convert-ToVersion ([string]$state.latestVersion)
    }
    catch {
        return $null
    }
}

function Test-ManifestSignature {
    param(
        [byte[]] $ManifestBytes,
        [string] $SignatureText,
        [string] $PublicKeyXml = $TrustedPublicKeyXml
    )

    try {
        $signatureBytes = [Convert]::FromBase64String($SignatureText.Trim())
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $rsa.FromXmlString($PublicKeyXml)
            return $rsa.VerifyData($ManifestBytes, "SHA256", $signatureBytes)
        }
        finally {
            $rsa.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Get-SafeManagedFiles {
    param([object] $Manifest)

    $files = @([string[]]$Manifest.managedFiles)
    if ($files.Count -eq 0) {
        throw "The signed manifest contains no managed files."
    }
    $seen = @{}
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace($file) -or $file -ne [System.IO.Path]::GetFileName($file) -or $file.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "The signed manifest contains an unsafe file name: $file"
        }
        if ($file.Equals("user", [System.StringComparison]::OrdinalIgnoreCase) -or $file.StartsWith("user\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The signed manifest attempted to manage user data."
        }
        $key = $file.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "The signed manifest contains a duplicate file: $file"
        }
        $seen[$key] = $true
    }
    return $files
}

function Read-AndVerifyManifest {
    param(
        [byte[]] $ManifestBytes,
        [string] $SignatureText,
        [version] $ExpectedVersion,
        [string] $PublicKeyXml = $TrustedPublicKeyXml
    )

    if (-not (Test-ManifestSignature -ManifestBytes $ManifestBytes -SignatureText $SignatureText -PublicKeyXml $PublicKeyXml)) {
        throw "The update manifest signature is invalid. Nothing was installed."
    }
    $manifest = [System.Text.Encoding]::UTF8.GetString($ManifestBytes) | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.product -ne $ProductId) {
        throw "The signed manifest belongs to an unsupported product or schema."
    }
    $manifestVersion = Convert-ToVersion ([string]$manifest.version)
    if ($manifestVersion -ne $ExpectedVersion) {
        throw "The signed manifest version does not match the GitHub release."
    }
    $expectedAsset = "FanficDownloader-$($ExpectedVersion.ToString(3)).zip"
    if ([string]$manifest.asset -cne $expectedAsset) {
        throw "The signed manifest names an unexpected package."
    }
    if ([string]$manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "The signed manifest contains an invalid SHA-256 value."
    }
    $null = Get-SafeManagedFiles -Manifest $manifest
    return $manifest
}

function Test-PowerShellFiles {
    param(
        [string] $Directory,
        [string[]] $Files
    )

    foreach ($file in @($Files | Where-Object { $_.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase) })) {
        $errors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Directory $file), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "The update contains an invalid PowerShell file: $file"
        }
    }
}

function Expand-VerifiedPackage {
    param(
        [string] $PackagePath,
        [string] $Destination,
        [string[]] $ManagedFiles
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entries = @($archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($entries.Count -gt $MaximumArchiveEntries) {
            throw "The update archive contains too many files."
        }
        if (($entries | Measure-Object Length -Sum).Sum -gt $MaximumExtractedBytes) {
            throw "The extracted update would be unexpectedly large."
        }
        $entryNames = @{}
        foreach ($entry in $entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name -ne [System.IO.Path]::GetFileName($name) -or $name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw "The update archive contains an unsafe path: $name"
            }
            $key = $name.ToLowerInvariant()
            if ($entryNames.ContainsKey($key)) {
                throw "The update archive contains a duplicate path: $name"
            }
            $entryNames[$key] = $true
        }
        $expected = @{}
        foreach ($file in $ManagedFiles) { $expected[$file.ToLowerInvariant()] = $true }
        if ($entryNames.Count -ne $expected.Count -or @($entryNames.Keys | Where-Object { -not $expected.ContainsKey($_) }).Count -gt 0) {
            throw "The update archive does not exactly match its signed file list."
        }
    }
    finally {
        $archive.Dispose()
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $Destination)
}

function Remove-OldUpdateData {
    $backupRoot = Join-Path $UpdateDirectory "backups"
    if (Test-Path -LiteralPath $backupRoot) {
        $oldBackups = @(Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip $RetainedBackups)
        foreach ($backup in $oldBackups) {
            [System.IO.Directory]::Delete($backup.FullName, $true)
        }
    }
    if (Test-Path -LiteralPath $UpdateLogDirectory) {
        $oldLogs = @(Get-ChildItem -LiteralPath $UpdateLogDirectory -File -Filter "update-*.log" | Sort-Object LastWriteTime -Descending | Select-Object -Skip $RetainedLogs)
        foreach ($log in $oldLogs) {
            Remove-Item -LiteralPath $log.FullName -Force
        }
    }
}

function Install-VerifiedUpdate {
    param(
        [string] $PackagePath,
        [byte[]] $ManifestBytes,
        [string] $SignatureText,
        [version] $ExpectedVersion,
        [string] $PublicKeyXml = $TrustedPublicKeyXml,
        [string] $TargetDirectory = $ResolvedAppDirectory
    )

    $manifest = Read-AndVerifyManifest -ManifestBytes $ManifestBytes -SignatureText $SignatureText -ExpectedVersion $ExpectedVersion -PublicKeyXml $PublicKeyXml
    $actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$manifest.sha256).ToLowerInvariant()) {
        throw "The update package failed its signed SHA-256 check. Nothing was installed."
    }

    $managedFiles = @(Get-SafeManagedFiles -Manifest $manifest)
    $targetRoot = [System.IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
    $targetUser = Join-Path $targetRoot "user"
    $targetUpdates = Join-Path $targetUser "updates"
    $stagingRoot = Join-Path $targetUpdates ("staging\" + [guid]::NewGuid().ToString('N'))
    $extracted = Join-Path $stagingRoot "extracted"
    $backupRoot = Join-Path $targetUpdates "backups"
    $currentVersion = Get-InstalledVersion -Directory $targetRoot
    $backup = Join-Path $backupRoot ("$($currentVersion.ToString(3))-" + (Get-Date -Format "yyyy-MM-dd_HHmmss"))
    $backupCreated = $false
    New-Item -ItemType Directory -Force -Path $extracted, $backup | Out-Null
    try {
        Expand-VerifiedPackage -PackagePath $PackagePath -Destination $extracted -ManagedFiles $managedFiles
        Test-PowerShellFiles -Directory $extracted -Files $managedFiles
        $stagedVersion = Get-InstalledVersion -Directory $extracted
        if ($stagedVersion -ne $ExpectedVersion) {
            throw "The extracted package reports the wrong version."
        }

        foreach ($file in $managedFiles) {
            $existing = Join-Path $targetRoot $file
            if (Test-Path -LiteralPath $existing -PathType Leaf) {
                Copy-Item -LiteralPath $existing -Destination (Join-Path $backup $file)
            }
        }
        $backupCreated = $true

        foreach ($file in $managedFiles) {
            $source = Join-Path $extracted $file
            $destination = Join-Path $targetRoot $file
            $temporary = "$destination.$([guid]::NewGuid().ToString('N')).new"
            Copy-Item -LiteralPath $source -Destination $temporary
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        }
        Test-PowerShellFiles -Directory $targetRoot -Files $managedFiles
        if ((Get-InstalledVersion -Directory $targetRoot) -ne $ExpectedVersion) {
            throw "The installed program did not retain the expected version."
        }
        return $manifest
    }
    catch {
        if ($backupCreated) {
            foreach ($file in $managedFiles) {
                $destination = Join-Path $targetRoot $file
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
                }
                $saved = Join-Path $backup $file
                if (Test-Path -LiteralPath $saved -PathType Leaf) {
                    Copy-Item -LiteralPath $saved -Destination $destination -Force
                }
            }
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            [System.IO.Directory]::Delete($stagingRoot, $true)
        }
    }
}

function Invoke-ReleaseInstall {
    param([object] $Release)

    $downloadDirectory = Join-Path $UpdateDirectory ("download-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null
    try {
        Write-UpdateStatus "Downloading Fanfic Downloader $($Release.VersionText)."
        $manifestBytes = Get-HttpsBytes -Url $Release.Manifest.Url -MaximumBytes $MaximumMetadataBytes
        $signatureBytes = Get-HttpsBytes -Url $Release.Signature.Url -MaximumBytes 64KB
        $signatureText = [System.Text.Encoding]::ASCII.GetString($signatureBytes)
        $manifest = Read-AndVerifyManifest -ManifestBytes $manifestBytes -SignatureText $signatureText -ExpectedVersion $Release.Version
        $packageBytes = Get-HttpsBytes -Url $Release.Package.Url -MaximumBytes $MaximumPackageBytes
        $packagePath = Join-Path $downloadDirectory ([string]$manifest.asset)
        [System.IO.File]::WriteAllBytes($packagePath, $packageBytes)
        $null = Install-VerifiedUpdate -PackagePath $packagePath -ManifestBytes $manifestBytes -SignatureText $signatureText -ExpectedVersion $Release.Version
        Write-UpdateState -LatestVersion $Release.Version -PageUrl $Release.PageUrl
        Remove-OldUpdateData
        Write-UpdateStatus "Fanfic Downloader $($Release.VersionText) was installed successfully." -Always
    }
    finally {
        if (Test-Path -LiteralPath $downloadDirectory) {
            [System.IO.Directory]::Delete($downloadDirectory, $true)
        }
    }
}

if ($LibraryOnly) {
    return
}

New-Item -ItemType Directory -Force -Path $UpdateLogDirectory | Out-Null
$UpdateLogPath = Join-Path $UpdateLogDirectory ("update-" + (Get-Date -Format "yyyy-MM-dd_HHmmss") + ".log")

try {
    $installedVersion = Get-InstalledVersion
    if ($CheckOnly -and -not $ForceCheck) {
        $cachedVersion = Get-CachedLatestVersion
        if ($cachedVersion) {
            if ($cachedVersion -gt $installedVersion) {
                Write-UpdateStatus "Fanfic Downloader $($cachedVersion.ToString(3)) is available." -Always
                exit 10
            }
            Write-UpdateStatus "Fanfic Downloader is up to date."
            exit 0
        }
    }

    Write-UpdateStatus "Checking GitHub for Fanfic Downloader updates."
    $release = Get-LatestRelease
    Write-UpdateState -LatestVersion $release.Version -PageUrl $release.PageUrl
    if ($release.Version -le $installedVersion) {
        Write-UpdateStatus "Fanfic Downloader $($installedVersion.ToString(3)) is up to date." -Always
        Remove-OldUpdateData
        exit 0
    }

    if ($CheckOnly) {
        Write-UpdateStatus "Fanfic Downloader $($release.VersionText) is available." -Always
        exit 10
    }

    if (-not $Install) {
        Write-UpdateStatus "Fanfic Downloader $($release.VersionText) is available." -Always
        if ($NonInteractive -or [Console]::IsInputRedirected) {
            Write-UpdateStatus "Run Update Fanfic Downloader.cmd to install it." -Always
            exit 10
        }
        $answer = Read-Host "Install this update now? Y/N"
        if ($answer -notmatch '^(?i)y(?:es)?$') {
            Write-UpdateStatus "Update cancelled."
            exit 0
        }
    }

    Invoke-ReleaseInstall -Release $release
    exit 0
}
catch {
    Write-UpdateStatus "Update failed: $($_.Exception.Message)" -Always
    Write-UpdateStatus "Nothing in the user folder was changed." -Always
    exit 2
}
