[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $PrepareOnly,
    [switch] $LibraryOnly,
    [switch] $SkipUpdateCheck,
    [string] $PrepareInput,
    [string] $PrepareResult,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $UrlParts
)

$ErrorActionPreference = "Continue"

function Read-SimpleIni {
    param([string] $Path)

    $data = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $data
    }

    $section = "default"
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith(";") -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            if (-not $data.ContainsKey($section)) {
                $data[$section] = @{}
            }
            continue
        }
        if ($trimmed -match '^(.*?)=(.*)$') {
            if (-not $data.ContainsKey($section)) {
                $data[$section] = @{}
            }
            $key = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim()
            $data[$section][$key] = $value
        }
    }

    return $data
}

function Get-ConfigValue {
    param(
        [hashtable] $Config,
        [string] $Section,
        [string] $Key,
        [string] $Default = ""
    )

    $sectionKey = $Section.ToLowerInvariant()
    $valueKey = $Key.ToLowerInvariant()
    if ($Config.ContainsKey($sectionKey) -and $Config[$sectionKey].ContainsKey($valueKey)) {
        return $Config[$sectionKey][$valueKey]
    }
    return $Default
}

function Get-ConfigBool {
    param(
        [hashtable] $Config,
        [string] $Section,
        [string] $Key,
        [bool] $Default
    )

    $value = (Get-ConfigValue -Config $Config -Section $Section -Key $Key -Default "").Trim().ToLowerInvariant()
    if ($value -in @("1", "true", "yes", "y", "on")) {
        return $true
    }
    if ($value -in @("0", "false", "no", "n", "off")) {
        return $false
    }
    return $Default
}

function Resolve-ConfigPath {
    param(
        [string] $Value,
        [string] $BaseDir
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }
    return Join-Path $BaseDir $expanded
}

function Get-ConfigFileText {
    param(
        [string] $Path,
        [string] $Default
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return $Default
}

function Remove-FileWithRetry {
    param(
        [string] $Path,
        [int] $Attempts = 6
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $true
    }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) {
                return $true
            }
        }
        catch {
            if ($attempt -eq $Attempts) {
                return $false
            }
        }
        Start-Sleep -Milliseconds (100 * $attempt)
    }
    return -not (Test-Path -LiteralPath $Path)
}

function Remove-AbandonedQueueArtifacts {
    param(
        [string] $Directory,
        [datetime] $OlderThan = ([DateTime]::UtcNow.AddMinutes(-15))
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^\.failed-urls-.*\.(?:tmp|backup)$' -and $_.LastWriteTimeUtc -lt $OlderThan
    })) {
        $null = Remove-FileWithRetry -Path $file.FullName
    }
}

function Initialize-DownloaderLog {
    param([string] $LogDirectory)

    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $currentLog = Join-Path $LogDirectory "downloader.log"
    $previousLog = Join-Path $LogDirectory "downloader-previous.log"
    if (Remove-FileWithRetry -Path $previousLog) {
        if (Test-Path -LiteralPath $currentLog -PathType Leaf) {
            try {
                Move-Item -LiteralPath $currentLog -Destination $previousLog -Force -ErrorAction Stop
            }
            catch {
                $null = Remove-FileWithRetry -Path $currentLog
            }
        }
    }
    foreach ($legacyLog in @(Get-ChildItem -LiteralPath $LogDirectory -File -Filter "download-*.log" -ErrorAction SilentlyContinue)) {
        $null = Remove-FileWithRetry -Path $legacyLog.FullName
    }
    Remove-AbandonedQueueArtifacts -Directory $LogDirectory
    return $currentLog
}

function Move-LegacyFailedUrlQueue {
    param(
        [string] $SourcePath,
        [string] $DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return
    }
    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($path in @($DestinationPath, $SourcePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            $key = $trimmed.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $lines.Add($trimmed)
            }
        }
    }
    [System.IO.File]::WriteAllLines($DestinationPath, [string[]]$lines, [System.Text.Encoding]::ASCII)
    $null = Remove-FileWithRetry -Path $SourcePath
}

function Test-FilesEquivalent {
    param(
        [string] $FirstPath,
        [string] $SecondPath
    )

    $first = Get-Item -LiteralPath $FirstPath -ErrorAction Stop
    $second = Get-Item -LiteralPath $SecondPath -ErrorAction Stop
    if ($first.Length -ne $second.Length) {
        return $false
    }
    return (Get-FileHash -LiteralPath $FirstPath -Algorithm SHA256 -ErrorAction Stop).Hash -eq
        (Get-FileHash -LiteralPath $SecondPath -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Move-LegacyUserFile {
    param(
        [string] $SourcePath,
        [string] $DestinationPath,
        [string] $ConflictDirectory
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return
    }

    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $destinationDirectory -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -ErrorAction Stop
        return
    }
    if (Test-FilesEquivalent -FirstPath $SourcePath -SecondPath $DestinationPath) {
        Remove-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
        return
    }

    New-Item -ItemType Directory -Force -Path $ConflictDirectory -ErrorAction Stop | Out-Null
    $conflictPath = Join-Path $ConflictDirectory (Split-Path -Leaf $SourcePath)
    if (Test-Path -LiteralPath $conflictPath) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($conflictPath)
        $extension = [System.IO.Path]::GetExtension($conflictPath)
        $conflictPath = Join-Path $ConflictDirectory ("$baseName-$([guid]::NewGuid().ToString('N'))$extension")
    }
    Move-Item -LiteralPath $SourcePath -Destination $conflictPath -ErrorAction Stop
}

function Move-LegacyUserDirectory {
    param(
        [string] $SourceDirectory,
        [string] $DestinationDirectory,
        [string] $ConflictDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        return
    }
    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        Move-Item -LiteralPath $SourceDirectory -Destination $DestinationDirectory -ErrorAction Stop
        return
    }

    $sourceRoot = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction Stop)) {
        $relativePath = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
        Move-LegacyUserFile `
            -SourcePath $sourceFile.FullName `
            -DestinationPath (Join-Path $DestinationDirectory $relativePath) `
            -ConflictDirectory (Join-Path $ConflictDirectory $relativePath.Substring(0, [Math]::Max(0, $relativePath.LastIndexOf('\'))))
    }

    if (@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction Stop).Count -eq 0) {
        [System.IO.Directory]::Delete($sourceRoot, $true)
    }
}

function Initialize-UserDirectory {
    param([string] $AppDirectory)

    $resolvedAppDirectory = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\')
    $userDirectory = Join-Path $resolvedAppDirectory "user"
    New-Item -ItemType Directory -Force -Path $userDirectory -ErrorAction Stop | Out-Null

    $conflictDirectory = Join-Path $userDirectory ("migration-conflicts\" + (Get-Date -Format "yyyy-MM-dd_HHmmss"))
    foreach ($fileName in @("downloader.ini", "fanficfare_personal.ini", "fanfiction-net-cookies.txt")) {
        Move-LegacyUserFile `
            -SourcePath (Join-Path $resolvedAppDirectory $fileName) `
            -DestinationPath (Join-Path $userDirectory $fileName) `
            -ConflictDirectory $conflictDirectory
    }
    foreach ($directoryName in @("logs", "downloads")) {
        Move-LegacyUserDirectory `
            -SourceDirectory (Join-Path $resolvedAppDirectory $directoryName) `
            -DestinationDirectory (Join-Path $userDirectory $directoryName) `
            -ConflictDirectory (Join-Path $conflictDirectory $directoryName)
    }

    return $userDirectory
}

$scriptFile = $MyInvocation.MyCommand.Path
$appDir = Split-Path -Parent $scriptFile
$userDir = Initialize-UserDirectory -AppDirectory $appDir
$settingsPath = Join-Path $userDir "downloader.ini"
$settings = Read-SimpleIni -Path $settingsPath
$fff = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "fanficfare_exe" -Default "fanficfare_env\Scripts\fanficfare.exe") -BaseDir $appDir
$config = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "fanficfare_config" -Default "fanficfare_personal.ini") -BaseDir $userDir
$outDir = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "output_dir" -Default "downloads") -BaseDir $userDir
$logDir = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "log_dir" -Default "logs") -BaseDir $userDir
$readerPath = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "reader_path" -Default "") -BaseDir $userDir
$browserEpubFolder = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "paths" -Key "browser_epub_folder" -Default "") -BaseDir $userDir
$downloadFormat = (Get-ConfigValue -Config $settings -Section "download" -Key "format" -Default "epub").Trim().ToLowerInvariant()
$openAfterDownload = Get-ConfigBool -Config $settings -Section "download" -Key "open_after_download" -Default $true
$readClipboard = Get-ConfigBool -Config $settings -Section "download" -Key "read_clipboard" -Default $true
$autoStartClipboard = Get-ConfigBool -Config $settings -Section "download" -Key "auto_start_clipboard" -Default $true
$preferNative = Get-ConfigBool -Config $settings -Section "download" -Key "prefer_native" -Default $true
$useFichub = Get-ConfigBool -Config $settings -Section "download" -Key "use_fichub" -Default $true
$useFichubForAo3 = Get-ConfigBool -Config $settings -Section "download" -Key "use_fichub_for_ao3" -Default $true
$allowUnverifiedAo3Cache = Get-ConfigBool -Config $settings -Section "download" -Key "allow_unverified_ao3_cache" -Default $false
$fallbackHtmlToEpub = Get-ConfigBool -Config $settings -Section "download" -Key "fallback_html_to_epub" -Default $true
$retryFailedUrls = Get-ConfigBool -Config $settings -Section "download" -Key "retry_failed_urls" -Default $true
$nativeTimeoutSeconds = [int](Get-ConfigValue -Config $settings -Section "download" -Key "native_timeout_seconds" -Default "90")
$nativeTimeoutMs = [Math]::Max(10, $nativeTimeoutSeconds) * 1000
$preparationTimeoutSeconds = [int](Get-ConfigValue -Config $settings -Section "download" -Key "preparation_timeout_seconds" -Default "120")
$preparationTimeoutSeconds = [Math]::Max(15, $preparationTimeoutSeconds)
$publishRetrySeconds = [int](Get-ConfigValue -Config $settings -Section "download" -Key "publish_retry_seconds" -Default "30")
$publishRetrySeconds = [Math]::Max(0, $publishRetrySeconds)
$removeAfterword = Get-ConfigBool -Config $settings -Section "cleanup" -Key "remove_afterword" -Default $true
$removeChapterNotes = Get-ConfigBool -Config $settings -Section "cleanup" -Key "remove_chapter_notes" -Default $true
$removeSeparatorLines = Get-ConfigBool -Config $settings -Section "cleanup" -Key "remove_separator_lines" -Default $true
$applyOldTemplateStyle = Get-ConfigBool -Config $settings -Section "cleanup" -Key "apply_old_template_style" -Default $true
$makeStoryUrlClickable = Get-ConfigBool -Config $settings -Section "cleanup" -Key "make_story_url_clickable" -Default $true
$pauseOnError = Get-ConfigBool -Config $settings -Section "accessibility" -Key "pause_on_error" -Default $true
$showWaitMessages = Get-ConfigBool -Config $settings -Section "accessibility" -Key "show_wait_messages" -Default $true
$checkForUpdates = Get-ConfigBool -Config $settings -Section "updates" -Key "check_for_updates" -Default $true
$promptForUpdates = Get-ConfigBool -Config $settings -Section "updates" -Key "prompt_to_install" -Default $true
$userAgent = Get-ConfigValue -Config $settings -Section "advanced" -Key "user_agent" -Default "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
$fichubUserAgent = Get-ConfigValue -Config $settings -Section "advanced" -Key "fichub_user_agent" -Default "AO3-Downloader/1.0"
$separatorTextRegex = Get-ConfigValue -Config $settings -Section "cleanup_patterns" -Key "separator_text_regex" -Default '^x(?:[-_*~.\u2013\u2014]?x){2,}$'
$separatorLineRegex = Get-ConfigValue -Config $settings -Section "cleanup_patterns" -Key "separator_line_regex" -Default '(?im)^\s*(?:x\s*[-_*~.\u2013\u2014.]\s*){2,}x?\s*$'
$separatorBlockTags = Get-ConfigValue -Config $settings -Section "cleanup_patterns" -Key "separator_block_tags" -Default "p|center"
$skipChapterFileRegex = Get-ConfigValue -Config $settings -Section "template" -Key "skip_chapter_file_regex" -Default '(?i)(nav|toc|title|intro|introduction)\.(xhtml|html)$'
$chapterFileRegex = Get-ConfigValue -Config $settings -Section "template" -Key "chapter_file_regex" -Default '(?i)(^|/)chap(?:ter)?[_-]?\d+\.'
$chapterHeadingFormat = Get-ConfigValue -Config $settings -Section "template" -Key "chapter_heading_format" -Default 'Chapter {number}: {title}'
$templateCssPath = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "template" -Key "stylesheet_css" -Default "template.css") -BaseDir $appDir
$pageCssPath = Resolve-ConfigPath -Value (Get-ConfigValue -Config $settings -Section "template" -Key "page_styles_css" -Default "page_styles.css") -BaseDir $appDir

$defaultTemplateCss = @'
body { background-color: #ffffff; text-align: left; margin: 8px; adobe-hyphenate: none; }
h1 { text-align: left; }
h2 { text-align: left; }
h3 { text-align: left; }
'@

$defaultPageCss = @'
@page {
  margin-bottom: 5pt;
  margin-top: 5pt;
}
'@

$templateCss = Get-ConfigFileText -Path $templateCssPath -Default $defaultTemplateCss
$pageCss = Get-ConfigFileText -Path $pageCssPath -Default $defaultPageCss

New-Item -ItemType Directory -Force -Path $logDir, $outDir | Out-Null

$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Initialize-DownloaderLog -LogDirectory $logDir
$started = Get-Date
$stageDir = Join-Path $env:TEMP "ao3-downloader-$stamp-$PID"
if (-not $LibraryOnly) {
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
}
$failedUrlSetting = Get-ConfigValue -Config $settings -Section "paths" -Key "failed_url_file" -Default ""
if ([string]::IsNullOrWhiteSpace($failedUrlSetting)) {
    $failedUrlFile = Join-Path $userDir "failed-urls.txt"
    Move-LegacyFailedUrlQueue -SourcePath (Join-Path $logDir "failed-urls.txt") -DestinationPath $failedUrlFile
}
else {
    $failedUrlFile = Resolve-ConfigPath -Value $failedUrlSetting -BaseDir $userDir
}
Remove-AbandonedQueueArtifacts -Directory (Split-Path -Parent $failedUrlFile)
$failedUrls = @()
$hadErrors = $false
$chapterHistoryFile = Join-Path $userDir "chapter-history.json"

function Write-Log {
    param([string] $Message)
    $Message | Out-File -LiteralPath $logFile -Append -Encoding utf8
}

function Write-Status {
    param([string] $Message)
    Write-Host $Message
    Write-Log $Message
}

function Read-Ao3ChapterHistory {
    param([string] $Path)

    $history = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $history
    }

    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $data -or $data -isnot [pscustomobject]) {
        throw "AO3 chapter history is not a JSON object."
    }
    foreach ($property in $data.PSObject.Properties) {
        $count = 0
        if ($property.Name -notmatch '^ao3:\d+$' -or
            -not [int]::TryParse([string]$property.Value, [ref]$count) -or $count -lt 1) {
            throw "AO3 chapter history contains an invalid work ID or chapter count."
        }
        $history[$property.Name] = $count
    }
    return $history
}

function Save-Ao3ChapterHistory {
    param([string] $Path, [hashtable] $History)

    $orderedHistory = [ordered]@{}
    foreach ($key in @($History.Keys | Sort-Object)) {
        if ($key -notmatch '^ao3:\d+$' -or [int]$History[$key] -lt 1) {
            throw "Refusing to save an invalid AO3 chapter history entry."
        }
        $orderedHistory[$key] = [int]$History[$key]
    }

    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".chapter-history-" + [guid]::NewGuid().ToString("N") + ".tmp")
    $backup = "$Path.backup-" + [guid]::NewGuid().ToString("N")
    try {
        $json = ConvertTo-Json -InputObject $orderedHistory -Depth 3
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temporary, $Path, $backup, $true)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary, $backup -Force -ErrorAction SilentlyContinue
    }
}

function Get-KnownAo3ChapterCount {
    param([string] $StoryUrl)

    if ($StoryUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)(?:[/?#]|$)') {
        return 0
    }
    $key = "ao3:$($Matches['id'])"
    if ($chapterHistory.ContainsKey($key)) {
        return [int]$chapterHistory[$key]
    }
    return 0
}

function Record-Ao3ChapterCount {
    param([string] $StoryUrl, [int] $ChapterCount)

    if ($StoryUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)(?:[/?#]|$)' -or $ChapterCount -lt 1) {
        return
    }
    $key = "ao3:$($Matches['id'])"
    if ($chapterHistory.ContainsKey($key) -and [int]$chapterHistory[$key] -ge $ChapterCount) {
        return
    }
    if ($chapterHistoryReadOnly) {
        throw "AO3 chapter history could not be read and was not replaced."
    }
    $updated = @{}
    foreach ($existingKey in $chapterHistory.Keys) {
        $updated[$existingKey] = [int]$chapterHistory[$existingKey]
    }
    $updated[$key] = $ChapterCount
    Save-Ao3ChapterHistory -Path $chapterHistoryFile -History $updated
    $chapterHistory[$key] = $ChapterCount
}

function Remove-DownloaderStage {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        $resolvedStage = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.Path]::GetDirectoryName($resolvedStage) -ne $resolvedTemp -or [System.IO.Path]::GetFileName($resolvedStage) -notlike "ao3-downloader-*") {
            throw "Refusing to remove an unexpected staging path: $resolvedStage"
        }
        [System.IO.Directory]::Delete($resolvedStage, $true)
    }
    catch {
        Write-Log "Could not remove temporary staging directory `"$Path`": $($_.Exception.Message)"
    }
}

function Remove-DownloaderStagesForProcessId {
    param([int] $ProcessId)

    foreach ($directory in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter "ao3-downloader-*-$ProcessId" -Force -ErrorAction SilentlyContinue)) {
        Remove-DownloaderStage -Path $directory.FullName
    }
}

function Invoke-StartupUpdateCheck {
    if ($SkipUpdateCheck -or -not $checkForUpdates) {
        return $false
    }
    $updaterPath = Join-Path $appDir "Update-FanficDownloader.ps1"
    if (-not (Test-Path -LiteralPath $updaterPath)) {
        return $false
    }

    try {
        $checkOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updaterPath -CheckOnly -Quiet 2>&1)
        $checkExitCode = $LASTEXITCODE
        if ($checkExitCode -eq 0) {
            return $false
        }
        if ($checkExitCode -ne 10) {
            Write-Log "Update check could not complete; continuing with the installed version."
            foreach ($line in $checkOutput) { Write-Log ([string]$line) }
            return $false
        }

        foreach ($line in $checkOutput) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Status ([string]$line)
            }
        }
        if (-not $promptForUpdates -or [Console]::IsInputRedirected) {
            Write-Status "Run Update Fanfic Downloader.cmd when convenient to install it."
            return $false
        }

        $answer = Read-Host "Install this update before downloading? Y/N"
        if ($answer -notmatch '^(?i)y(?:es)?$') {
            Write-Status "Continuing without updating."
            return $false
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updaterPath -Install -NonInteractive
        if ($LASTEXITCODE -ne 0) {
            Write-Status "The update did not install; continuing with the current version."
            return $false
        }
        return $true
    }
    catch {
        Write-Log "Update check failed; continuing with the installed version: $($_.Exception.Message)"
        return $false
    }
}

function Close-WithError {
    param(
        [int] $Code,
        [string] $Message
    )

    if ($Message) {
        Write-Host $Message
        Write-Log $Message
    }
    Write-Log ""
    Write-Log "Log saved to: `"$logFile`""
    Write-Host "Log saved to: `"$logFile`""
    if ($pauseOnError) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
    foreach ($temporaryConfig in @($loginConfig, $runtimeFanficfareConfig)) {
        if (-not [string]::IsNullOrWhiteSpace($temporaryConfig)) {
            Remove-Item -LiteralPath $temporaryConfig -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-DownloaderStage -Path $stageDir
    exit $Code
}

function Read-FailedUrlQueue {
    if (-not (Test-Path -LiteralPath $failedUrlFile)) {
        return @()
    }

    $queueText = Get-Content -LiteralPath $failedUrlFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($queueText)) {
        return @()
    }
    return @(Get-SupportedDownloadUrls $queueText)
}

function Set-FailedUrlQueue {
    param([string[]] $Urls)

    $uniqueUrls = @(Select-PreferredDownloadUrls -Urls $Urls)

    if ($uniqueUrls.Count -eq 0) {
        Remove-Item -LiteralPath $failedUrlFile -Force -ErrorAction SilentlyContinue
        return
    }

    $queueDir = Split-Path -Parent $failedUrlFile
    New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
    $queueId = "$PID-" + [guid]::NewGuid().ToString("N")
    $temporaryQueue = Join-Path $queueDir ".failed-urls-$queueId.tmp"
    $backupQueue = Join-Path $queueDir ".failed-urls-$queueId.backup"
    try {
        [System.IO.File]::WriteAllLines($temporaryQueue, [string[]]$uniqueUrls, [System.Text.Encoding]::ASCII)
        if (Test-Path -LiteralPath $failedUrlFile) {
            [System.IO.File]::Replace($temporaryQueue, $failedUrlFile, $backupQueue, $true)
        }
        else {
            [System.IO.File]::Move($temporaryQueue, $failedUrlFile)
        }
    }
    finally {
        $null = Remove-FileWithRetry -Path $temporaryQueue
        $null = Remove-FileWithRetry -Path $backupQueue
    }
}

function Save-FailedUrls {
    param([string[]] $Urls)

    $urlsToAdd = @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($urlsToAdd.Count -eq 0) {
        return
    }
    $existingUrls = @(Read-FailedUrlQueue)
    Set-FailedUrlQueue -Urls @($existingUrls + @($urlsToAdd))
    Write-Status "Failed URL queue saved: `"$failedUrlFile`""
}

function Remove-CompletedFailedUrls {
    param([string[]] $Urls)

    $removeKeys = @{}
    foreach ($url in @($Urls)) {
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            $removeKeys[(Get-DownloadStoryKey $url)] = $true
        }
    }
    if ($removeKeys.Count -eq 0) {
        return
    }

    $existing = @(Read-FailedUrlQueue)
    $remaining = @($existing | Where-Object {
        -not $removeKeys.ContainsKey((Get-DownloadStoryKey $_))
    })
    if ($remaining.Count -eq $existing.Count) {
        return
    }

    Set-FailedUrlQueue -Urls $remaining
    if ($remaining.Count -eq 0) {
        Write-Status "All queued failed URLs completed; removed `"$failedUrlFile`"."
    }
    else {
        Write-Status "Removed completed URL(s) from the failed queue; $($remaining.Count) remain."
    }
}

function Get-PotentialSuccessfulEpubs {
    $stageFics = @()
    if (Test-Path -LiteralPath $stageDir) {
        $stageFics = @(Get-ChildItem -LiteralPath $stageDir -Filter "*.$downloadFormat" -File -ErrorAction SilentlyContinue)
    }

    return @($fics + $stageFics | Where-Object { $_ } | Sort-Object FullName -Unique)
}

function Test-FanFicFareLoginFailure {
    param([string] $Stdout, [string] $Stderr)

    return "$Stdout`n$Stderr" -match 'Login Failed on non-interactive process'
}

function Get-HttpStatusCode {
    param([Exception] $ErrorException)

    $current = $ErrorException
    while ($current) {
        if ($current -is [System.Net.WebException] -and $current.Response -and $current.Response.StatusCode) {
            return [int]$current.Response.StatusCode
        }
        $current = $current.InnerException
    }
    if ($ErrorException.Message -match '\((?<status>[45]\d\d)\)') {
        return [int]$Matches['status']
    }
    return 0
}

function Convert-StoryUrlToLink {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($EpubPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })

        foreach ($entry in $entries) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try {
                $content = $reader.ReadToEnd()
            }
            finally {
                $reader.Close()
            }

            $updated = [regex]::Replace(
                $content,
                '<p>URL:\s*(https?://[^<\s]+)</p>',
                {
                    param($match)
                    $href = [System.Security.SecurityElement]::Escape($match.Groups[1].Value)
                    "<p>URL: <a href=`"$href`">$href</a></p>"
                },
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($updated -ne $content) {
                $entryName = $entry.FullName
                $entry.Delete()
                $newEntry = $zip.CreateEntry($entryName)
                $writer = New-Object System.IO.StreamWriter($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write($updated)
                }
                finally {
                    $writer.Close()
                }
                return $true
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    return $false
}

function Read-ZipEntryText {
    param([System.IO.Compression.ZipArchiveEntry] $Entry)

    $reader = New-Object System.IO.StreamReader($Entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Close()
    }
}

function Replace-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive] $Zip,
        [System.IO.Compression.ZipArchiveEntry] $Entry,
        [string] $Content
    )

    $entryName = $Entry.FullName
    $Entry.Delete()
    $newEntry = $Zip.CreateEntry($entryName)
    $writer = New-Object System.IO.StreamWriter($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
        $writer.Write($Content)
    }
    finally {
        $writer.Close()
    }
}

function ConvertTo-EpubXmlDocument {
    param(
        [string] $Content,
        [string] $EntryName
    )

    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    try {
        $document.LoadXml($Content)
    }
    catch {
        $message = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $message = $_.Exception.InnerException.Message
        }
        throw "EPUB XML is invalid in ${EntryName}: $message"
    }
    return $document
}

function Repair-EpubXmlDeclarationWhitespace {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $changedCount = 0
    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $xmlEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(opf|ncx|xhtml|xml)$' -and $_.Length -gt 0
        })
        foreach ($entry in $xmlEntries) {
            $content = Read-ZipEntryText -Entry $entry
            $updated = [regex]::Replace($content, '^\s+(?=<\?xml(?:\s|\?>))', '')
            if ($updated -eq $content) {
                continue
            }
            Replace-ZipEntryText -Zip $zip -Entry $entry -Content $updated
            $changedCount++
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }
    return $changedCount
}

function Open-EpubForUpdate {
    param([string] $EpubPath)

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($EpubPath, [System.IO.Compression.ZipArchiveMode]::Update)
    }
    catch {
        throw "Could not edit EPUB `"$EpubPath`". Close it in Paperback or any other reader, then try again. $($_.Exception.Message)"
    }

    if (-not $zip) {
        throw "Could not edit EPUB `"$EpubPath`". Close it in Paperback or any other reader, then try again."
    }

    return $zip
}

function Resolve-EpubEntryPath {
    param(
        [string] $BaseEntryPath,
        [string] $RelativePath
    )

    $cleanRelative = ($RelativePath -replace '#.*$', '')
    if ([string]::IsNullOrWhiteSpace($cleanRelative) -or $cleanRelative -match '^[a-z][a-z0-9+.-]*:') {
        return $cleanRelative
    }

    $baseUri = [System.Uri]::new("https://epub.invalid/" + $BaseEntryPath.Replace('\', '/'))
    $resolved = [System.Uri]::new($baseUri, $cleanRelative)
    return [System.Uri]::UnescapeDataString($resolved.AbsolutePath.TrimStart('/'))
}

function Test-EpubIntegrity {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($EpubPath)
        $entries = @($zip.Entries)
        if ($entries.Count -eq 0) {
            throw "EPUB archive is empty."
        }
        if ($entries[0].FullName -ne "mimetype") {
            throw "The EPUB mimetype entry is not first in the archive."
        }

        $duplicate = $entries | Group-Object FullName | Where-Object { $_.Count -gt 1 } | Select-Object -First 1
        if ($duplicate) {
            throw "EPUB contains a duplicate entry: $($duplicate.Name)"
        }

        $mimetypeEntry = $zip.GetEntry("mimetype")
        if (-not $mimetypeEntry) {
            throw "EPUB has no mimetype entry."
        }
        if ((Read-ZipEntryText -Entry $mimetypeEntry).Trim() -ne "application/epub+zip") {
            throw "EPUB mimetype entry has unexpected content."
        }

        $containerEntry = $zip.GetEntry("META-INF/container.xml")
        if (-not $containerEntry) {
            throw "EPUB has no META-INF/container.xml entry."
        }
        $containerXml = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $containerEntry) -EntryName $containerEntry.FullName
        $rootfileNode = $containerXml.SelectSingleNode("//*[local-name()='rootfile']")
        if (-not $rootfileNode -or [string]::IsNullOrWhiteSpace($rootfileNode.GetAttribute("full-path"))) {
            throw "EPUB container does not identify a package document."
        }

        $opfPath = [System.Uri]::UnescapeDataString($rootfileNode.GetAttribute("full-path"))
        $opfEntry = $zip.GetEntry($opfPath)
        if (-not $opfEntry) {
            throw "EPUB package document is missing: $opfPath"
        }
        $opfXml = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $opfEntry) -EntryName $opfEntry.FullName

        $manifestIds = @{}
        foreach ($item in @($opfXml.SelectNodes("//*[local-name()='manifest']/*[local-name()='item']"))) {
            $id = $item.GetAttribute("id")
            $href = $item.GetAttribute("href")
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($href)) {
                throw "EPUB manifest contains an item without both id and href."
            }
            $manifestIds[$id] = $href
            if ($href -notmatch '^[a-z][a-z0-9+.-]*:') {
                $entryPath = Resolve-EpubEntryPath -BaseEntryPath $opfPath -RelativePath $href
                if (-not $zip.GetEntry($entryPath)) {
                    throw "EPUB manifest refers to a missing entry: $entryPath"
                }
            }
        }
        if ($manifestIds.Count -eq 0) {
            throw "EPUB manifest is empty."
        }

        foreach ($itemref in @($opfXml.SelectNodes("//*[local-name()='spine']/*[local-name()='itemref']"))) {
            $idref = $itemref.GetAttribute("idref")
            if ([string]::IsNullOrWhiteSpace($idref) -or -not $manifestIds.ContainsKey($idref)) {
                throw "EPUB spine refers to an unknown manifest id: $idref"
            }
        }

        foreach ($xmlEntry in @($entries | Where-Object {
            $_.FullName -match '\.(opf|ncx|xhtml)$' -or $_.FullName -eq "META-INF/container.xml"
        })) {
            $null = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $xmlEntry) -EntryName $xmlEntry.FullName
        }

        foreach ($navEntry in @($entries | Where-Object { $_.FullName -match '(^|/)nav\.xhtml$' })) {
            $navXml = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $navEntry) -EntryName $navEntry.FullName
            foreach ($anchor in @($navXml.SelectNodes("//*[local-name()='a']"))) {
                $href = $anchor.GetAttribute("href")
                if ([string]::IsNullOrWhiteSpace($href) -or $href.StartsWith("#") -or $href -match '^[a-z][a-z0-9+.-]*:') {
                    continue
                }
                $targetPath = Resolve-EpubEntryPath -BaseEntryPath $navEntry.FullName -RelativePath $href
                if (-not $zip.GetEntry($targetPath)) {
                    throw "EPUB navigation refers to a missing entry: $targetPath"
                }
            }
        }

        foreach ($ncxEntry in @($entries | Where-Object { $_.FullName -match '\.ncx$' })) {
            $ncxXml = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $ncxEntry) -EntryName $ncxEntry.FullName
            foreach ($contentNode in @($ncxXml.SelectNodes("//*[local-name()='content']"))) {
                $src = $contentNode.GetAttribute("src")
                if ([string]::IsNullOrWhiteSpace($src) -or $src -match '^[a-z][a-z0-9+.-]*:') {
                    continue
                }
                $targetPath = Resolve-EpubEntryPath -BaseEntryPath $ncxEntry.FullName -RelativePath $src
                if (-not $zip.GetEntry($targetPath)) {
                    throw "EPUB NCX refers to a missing entry: $targetPath"
                }
            }
        }

        return [pscustomobject]@{
            Valid = $true
            Message = "EPUB structure and XML are valid."
            EntryCount = $entries.Count
        }
    }
    catch {
        return [pscustomobject]@{
            Valid = $false
            Message = $_.Exception.Message
            EntryCount = 0
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }
}

function Remove-Ao3AfterwordFromEpub {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $afterwordNames = @()
        $contentEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })

        foreach ($entry in $contentEntries) {
            $content = Read-ZipEntryText -Entry $entry
            $firstHeading = [regex]::Match($content, '(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>')
            if ($firstHeading.Success -and (Get-PlainHtmlText $firstHeading.Groups[1].Value) -eq "Afterword") {
                $afterwordNames += $entry.FullName
            }
        }

        if ($afterwordNames.Count -eq 0) {
            return 0
        }

        $opfEntries = @($zip.Entries | Where-Object { $_.FullName -match '\.opf$' })
        foreach ($opfEntry in $opfEntries) {
            $opf = Read-ZipEntryText -Entry $opfEntry
            $updated = $opf
            $idsToRemove = New-Object System.Collections.Generic.List[string]
            $opfDir = ""
            if ($opfEntry.FullName.Contains("/")) {
                $opfDir = $opfEntry.FullName.Substring(0, $opfEntry.FullName.LastIndexOf("/"))
            }

            foreach ($name in $afterwordNames) {
                $href = $name
                if ($opfDir -and $name.StartsWith("$opfDir/")) {
                    $href = $name.Substring($opfDir.Length + 1)
                }

                $escapedHref = [regex]::Escape($href)
                $itemPattern = '(?is)<item\b(?=[^>]*\bhref\s*=\s*["'']' + $escapedHref + '["''])(?=[^>]*\bid\s*=\s*["'']([^"'']+)["''])[^>]*/>\s*'
                foreach ($match in [regex]::Matches($updated, $itemPattern)) {
                    $idsToRemove.Add($match.Groups[1].Value)
                }
                $updated = [regex]::Replace($updated, $itemPattern, '')
            }

            foreach ($id in $idsToRemove) {
                $escapedId = [regex]::Escape($id)
                $updated = [regex]::Replace($updated, '(?is)<itemref\b(?=[^>]*\bidref\s*=\s*["'']' + $escapedId + '["''])[^>]*/>\s*', '')
                $updated = [regex]::Replace($updated, '(?is)<reference\b(?=[^>]*\bhref\s*=\s*["''][^"'']*["''])(?=[^>]*\btitle\s*=\s*["'']Afterword["''])[^>]*/>\s*', '')
            }

            if ($updated -ne $opf) {
                Replace-ZipEntryText -Zip $zip -Entry $opfEntry -Content $updated
            }
        }

        $ncxEntries = @($zip.Entries | Where-Object { $_.FullName -match '\.ncx$' })
        foreach ($ncxEntry in $ncxEntries) {
            $ncx = Read-ZipEntryText -Entry $ncxEntry
            $ncxDocument = New-Object System.Xml.XmlDocument
            $ncxDocument.PreserveWhitespace = $true
            $ncxDocument.LoadXml($ncx)
            $ncxChanged = $false
            foreach ($navPoint in @($ncxDocument.SelectNodes("//*[local-name()='navPoint']"))) {
                $contentNode = $navPoint.SelectSingleNode("./*[local-name()='content']")
                if (-not $contentNode) {
                    continue
                }
                $targetPath = Resolve-EpubEntryPath -BaseEntryPath $ncxEntry.FullName -RelativePath $contentNode.GetAttribute("src")
                if ($afterwordNames -contains $targetPath) {
                    $null = $navPoint.ParentNode.RemoveChild($navPoint)
                    $ncxChanged = $true
                }
            }
            if ($ncxChanged) {
                Replace-ZipEntryText -Zip $zip -Entry $ncxEntry -Content $ncxDocument.OuterXml
            }
        }

        $navEntries = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)nav\.xhtml$' })
        foreach ($navEntry in $navEntries) {
            $nav = Read-ZipEntryText -Entry $navEntry
            $navDocument = New-Object System.Xml.XmlDocument
            $navDocument.PreserveWhitespace = $true
            $navDocument.LoadXml($nav)
            $navChanged = $false
            foreach ($anchor in @($navDocument.SelectNodes("//*[local-name()='a']"))) {
                $href = $anchor.GetAttribute("href")
                if ([string]::IsNullOrWhiteSpace($href) -or $href.StartsWith("#") -or $href -match '^[a-z][a-z0-9+.-]*:') {
                    continue
                }
                $targetPath = Resolve-EpubEntryPath -BaseEntryPath $navEntry.FullName -RelativePath $href
                if ($afterwordNames -notcontains $targetPath) {
                    continue
                }

                $nodeToRemove = $anchor
                $ancestor = $anchor.ParentNode
                while ($ancestor -and $ancestor -ne $navDocument.DocumentElement) {
                    if ($ancestor.LocalName -eq "li") {
                        $nodeToRemove = $ancestor
                        break
                    }
                    $ancestor = $ancestor.ParentNode
                }
                $null = $nodeToRemove.ParentNode.RemoveChild($nodeToRemove)
                $navChanged = $true
            }
            if ($navChanged) {
                Replace-ZipEntryText -Zip $zip -Entry $navEntry -Content $navDocument.OuterXml
            }
        }

        foreach ($name in $afterwordNames) {
            $entry = $zip.GetEntry($name)
            if ($entry) {
                $entry.Delete()
            }
        }

        return $afterwordNames.Count
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }
}

function Remove-Ao3ChapterNotesFromEpub {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $changedCount = 0
    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $contentEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })

        foreach ($entry in $contentEntries) {
            $content = Read-ZipEntryText -Entry $entry
            $updated = $content

            $updated = [regex]::Replace(
                $updated,
                '(?is)\s*<p\b[^>]*>\s*Chapter Notes\s*</p>\s*<blockquote\b[^>]*>.*?</blockquote>\s*',
                ''
            )
            $updated = [regex]::Replace(
                $updated,
                '(?is)\s*<p\b[^>]*>\s*Chapter Notes\s*</p>\s*<div\b[^>]*>\s*See the end of the chapter for\s*<a\b[^>]*>notes</a>\s*</div>\s*',
                ''
            )
            $updated = [regex]::Replace(
                $updated,
                '(?is)\s*<div\b[^>]*\bid=["'']endnotes[^"'']*["''][^>]*>\s*<p\b[^>]*>\s*Chapter End Notes\s*</p>\s*<blockquote\b[^>]*>.*?</blockquote>\s*</div>\s*',
                ''
            )

            if ($updated -ne $content) {
                Replace-ZipEntryText -Zip $zip -Entry $entry -Content $updated
                $changedCount++
            }
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }

    return $changedCount
}

function Test-SeparatorText {
    param([string] $Text)

    $normalized = ([regex]::Replace($Text, '\s+', '')).ToLowerInvariant()
    if ($normalized -eq "") {
        return $false
    }
    if ($normalized -match $separatorTextRegex) {
        return $true
    }
    return $false
}

function Remove-SeparatorLinesFromEpub {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $changedCount = 0
    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $contentEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })

        foreach ($entry in $contentEntries) {
            $content = Read-ZipEntryText -Entry $entry
            $updated = [regex]::Replace(
                $content,
                ('(?is)<(?<tag>' + $separatorBlockTags + ')\b[^>]*>.*?</\k<tag>>'),
                {
                    param($match)
                    $visibleText = Get-PlainHtmlText $match.Value
                    if (Test-SeparatorText -Text $visibleText) {
                        return ""
                    }
                    return $match.Value
                }
            )

            $updated = [regex]::Replace(
                $updated,
                $separatorLineRegex,
                ''
            )

            if ($updated -ne $content) {
                Replace-ZipEntryText -Zip $zip -Entry $entry -Content $updated
                $changedCount++
            }
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }

    return $changedCount
}

function Get-RelativeEpubPath {
    param(
        [string] $BasePath,
        [string] $TargetPath
    )

    $baseParts = @($BasePath -split '/' | Where-Object { $_ -ne "" })
    $targetParts = @($TargetPath -split '/' | Where-Object { $_ -ne "" })
    while ($baseParts.Count -gt 0 -and $targetParts.Count -gt 0 -and $baseParts[0] -eq $targetParts[0]) {
        $baseParts = @($baseParts | Select-Object -Skip 1)
        $targetParts = @($targetParts | Select-Object -Skip 1)
    }

    $relativeParts = @()
    if ($baseParts.Count -gt 1) {
        for ($i = 0; $i -lt ($baseParts.Count - 1); $i++) {
            $relativeParts += ".."
        }
    }
    $relativeParts += $targetParts
    return ($relativeParts -join '/')
}

function Normalize-ChapterHeadingText {
    param(
        [string] $HeadingText,
        [int] $ChapterNumber
    )

    $plain = Get-PlainHtmlText $HeadingText
    if ([string]::IsNullOrWhiteSpace($plain)) {
        $plain = "Chapter $ChapterNumber"
    }
    if ($plain -match '^\s*Chapter\s+\d+\s*:') {
        return $plain
    }
    if ($plain -match '^\s*Chapter\s+\d+\s*$') {
        return "Chapter $ChapterNumber"
    }
    return $chapterHeadingFormat.Replace("{number}", [string]$ChapterNumber).Replace("{title}", $plain)
}

function Normalize-EpubChapterHeadings {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $changed = $false
    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $opfEntry = $zip.Entries | Where-Object { $_.FullName -match '\.opf$' } | Select-Object -First 1
        if (-not $opfEntry) {
            return $false
        }

        $opf = Read-ZipEntryText -Entry $opfEntry
        $opfDir = ""
        if ($opfEntry.FullName.Contains("/")) {
            $opfDir = $opfEntry.FullName.Substring(0, $opfEntry.FullName.LastIndexOf("/"))
        }

        $manifest = @{}
        foreach ($match in [regex]::Matches($opf, '(?is)<item\b[^>]*\bid\s*=\s*["'']([^"'']+)["''][^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*/?>|<item\b[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*\bid\s*=\s*["'']([^"'']+)["''][^>]*/?>')) {
            if ($match.Groups[1].Success) {
                $id = $match.Groups[1].Value
                $href = $match.Groups[2].Value
            }
            else {
                $id = $match.Groups[4].Value
                $href = $match.Groups[3].Value
            }
            $manifest[$id] = [System.Uri]::UnescapeDataString($href)
        }

        $chapterInfo = @{}
        $chapterNumber = 0
        foreach ($spineMatch in [regex]::Matches($opf, '(?is)<itemref\b[^>]*\bidref\s*=\s*["'']([^"'']+)["''][^>]*/?>')) {
            $idref = $spineMatch.Groups[1].Value
            if (-not $manifest.ContainsKey($idref)) {
                continue
            }

            $href = $manifest[$idref]
            if ($href -notmatch '\.(xhtml|html)$') {
                continue
            }
            if ($href -match $skipChapterFileRegex) {
                continue
            }
            if ($href -notmatch $chapterFileRegex) {
                continue
            }

            $chapterNumber++
            $entryPath = if ($opfDir) { "$opfDir/$href" } else { $href }
            $entry = $zip.GetEntry($entryPath)
            if (-not $entry) {
                continue
            }

            $content = Read-ZipEntryText -Entry $entry
            $headingMatch = [regex]::Match($content, '(?is)<h(?<level>[1-6])\b(?<attrs>[^>]*)>(?<text>.*?)</h\k<level>>')
            if (-not $headingMatch.Success) {
                continue
            }

            $newText = Normalize-ChapterHeadingText -HeadingText $headingMatch.Groups["text"].Value -ChapterNumber $chapterNumber
            $escapedText = Escape-XmlText $newText
            $replacement = "<h$($headingMatch.Groups["level"].Value)$($headingMatch.Groups["attrs"].Value)>$escapedText</h$($headingMatch.Groups["level"].Value)>"
            $updated = $content.Substring(0, $headingMatch.Index) + $replacement + $content.Substring($headingMatch.Index + $headingMatch.Length)
            if ($updated -ne $content) {
                Replace-ZipEntryText -Zip $zip -Entry $entry -Content $updated
                $changed = $true
            }

            $chapterInfo[$entryPath] = $newText
        }

        if ($chapterInfo.Count -gt 0) {
            $tocEntries = @($zip.Entries | Where-Object {
                $_.FullName -match '(^|/)(nav\.xhtml|toc\.ncx)$' -and $_.Length -gt 0
            })
            foreach ($tocEntry in $tocEntries) {
                $toc = Read-ZipEntryText -Entry $tocEntry
                $tocMap = @{}
                foreach ($entryPath in $chapterInfo.Keys) {
                    $relativePath = Get-RelativeEpubPath -BasePath $tocEntry.FullName -TargetPath $entryPath
                    $tocMap[$relativePath] = $chapterInfo[$entryPath]
                    $tocMap[(Escape-XmlText $relativePath)] = $chapterInfo[$entryPath]
                }

                $updatedToc = $toc

                if ($tocEntry.FullName -match '(^|/)nav\.xhtml$') {
                    $updatedToc = [regex]::Replace(
                        $updatedToc,
                        '(?is)<a\b(?<attrs>[^>]*\bhref\s*=\s*["''](?<href>[^"'']+)["''][^>]*)>.*?</a>',
                        {
                            param($match)
                            $href = $match.Groups["href"].Value -replace '#.*$', ''
                            if ($tocMap.ContainsKey($href)) {
                                return "<a$($match.Groups["attrs"].Value)>$(Escape-XmlText $tocMap[$href])</a>"
                            }
                            return $match.Value
                        }
                    )
                }
                else {
                    $ncxDocument = New-Object System.Xml.XmlDocument
                    $ncxDocument.PreserveWhitespace = $true
                    $ncxDocument.LoadXml($updatedToc)
                    $ncxChanged = $false
                    foreach ($navPoint in @($ncxDocument.SelectNodes("//*[local-name()='navPoint']"))) {
                        $contentNode = $navPoint.SelectSingleNode("./*[local-name()='content']")
                        $labelNode = $navPoint.SelectSingleNode("./*[local-name()='navLabel']/*[local-name()='text']")
                        if (-not $contentNode -or -not $labelNode) {
                            continue
                        }
                        $src = $contentNode.GetAttribute("src") -replace '#.*$', ''
                        if ($tocMap.ContainsKey($src) -and $labelNode.InnerText -ne $tocMap[$src]) {
                            $labelNode.InnerText = $tocMap[$src]
                            $ncxChanged = $true
                        }
                    }
                    if ($ncxChanged) {
                        $updatedToc = $ncxDocument.OuterXml
                    }
                }

                if ($updatedToc -ne $toc) {
                    Replace-ZipEntryText -Zip $zip -Entry $tocEntry -Content $updatedToc
                    $changed = $true
                }
            }
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }

    return $changed
}

function Apply-OldTemplateStyleToEpub {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $changed = $false
    $zip = Open-EpubForUpdate -EpubPath $EpubPath
    try {
        $stylesheetEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.css$' -and $_.FullName -notmatch '(^|/)page_styles\.css$'
        })
        foreach ($entry in $stylesheetEntries) {
            Replace-ZipEntryText -Zip $zip -Entry $entry -Content $templateCss
            $changed = $true
        }

        $pageStyleEntries = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)page_styles\.css$' })
        foreach ($entry in $pageStyleEntries) {
            Replace-ZipEntryText -Zip $zip -Entry $entry -Content $pageCss
            $changed = $true
        }

        $contentEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })

        foreach ($entry in $contentEntries) {
            $content = Read-ZipEntryText -Entry $entry
            $updated = $content

            $updated = [regex]::Replace($updated, '<body\b[^>]*>', '<body>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $updated = [regex]::Replace(
                $updated,
                '(?is)<h2\b[^>]*\bclass=["''][^"'']*\bheading\b[^"'']*["''][^>]*>\s*(.*?)\s*</h2>',
                {
                    param($match)
                    "<h2>$($match.Groups[1].Value.Trim())</h2>"
                }
            )
            $updated = [regex]::Replace(
                $updated,
                '(?is)<h2\b[^>]*\bclass=["''][^"'']*\btoc-heading\b[^"'']*["''][^>]*>\s*(.*?)\s*</h2>',
                {
                    param($match)
                    "<h2>$($match.Groups[1].Value.Trim())</h2>"
                }
            )
            $updated = [regex]::Replace($updated, '\sclass=["''][^"'']*["'']', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

            if ($updated -ne $content) {
                Replace-ZipEntryText -Zip $zip -Entry $entry -Content $updated
                $changed = $true
            }
        }
    }
    finally {
        if ($zip) {
            $zip.Dispose()
        }
    }

    return $changed
}

function Get-SafeFileName {
    param([string] $Name)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($char in $invalid) {
        $Name = $Name.Replace($char, [char]"_")
    }
    $Name = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "AO3 Download"
    }
    return $Name
}

function Get-PlainHtmlText {
    param([string] $Html)

    $text = [regex]::Replace($Html, '<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function Escape-XmlText {
    param([string] $Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function Write-ZipTextEntry {
    param(
        [System.IO.Compression.ZipArchive] $Zip,
        [string] $Name,
        [string] $Content,
        [System.IO.Compression.CompressionLevel] $CompressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
    )

    $entry = $Zip.CreateEntry($Name, $CompressionLevel)
    $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
        $writer.Write($Content)
    }
    finally {
        $writer.Close()
    }
}

function Convert-Ao3HtmlDownloadToEpub {
    param(
        [string] $HtmlPath,
        [string] $WorkUrl,
        [string] $DestPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $html = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
    $titleMatch = [regex]::Match($html, '<h1[^>]*>(.*?)</h1>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $titleMatch.Success) {
        $titleMatch = [regex]::Match($html, '<title[^>]*>(.*?)</title>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    }

    $title = Get-PlainHtmlText $titleMatch.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "AO3 Download"
    }

    $bodyMatch = [regex]::Match($html, '<body[^>]*>(.*?)</body>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($bodyMatch.Success) {
        $body = $bodyMatch.Groups[1].Value
    }
    else {
        $body = $html
    }

    $chapterMatches = @([regex]::Matches($body, '<h2\s+class="heading"[^>]*>\s*(.*?)\s*</h2>', [System.Text.RegularExpressions.RegexOptions]::Singleline))
    $sections = New-Object System.Collections.Generic.List[object]
    if ($chapterMatches.Count -gt 0) {
        $intro = $body.Substring(0, $chapterMatches[0].Index)
        $sections.Add([pscustomobject]@{
            File = "title.html"
            Title = $title
            Html = $intro
        })

        for ($i = 0; $i -lt $chapterMatches.Count; $i++) {
            $start = $chapterMatches[$i].Index
            if ($i + 1 -lt $chapterMatches.Count) {
                $end = $chapterMatches[$i + 1].Index
            }
            else {
                $end = $body.Length
            }

            $chapterHtml = $body.Substring($start, $end - $start)
            $afterwordMatch = [regex]::Match($chapterHtml, '(?is)<div\b[^>]*\bid=["'']afterword["''][^>]*>|<h[1-6]\b[^>]*>\s*(?:<[^>]+>\s*)*Afterword\s*(?:<[^>]+>\s*)*</h[1-6]>')
            if ($afterwordMatch.Success) {
                $chapterHtml = $chapterHtml.Substring(0, $afterwordMatch.Index)
            }

            $chapterTitle = Get-PlainHtmlText $chapterMatches[$i].Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($chapterTitle)) {
                $chapterTitle = "Chapter $($i + 1)"
            }

            $sections.Add([pscustomobject]@{
                File = ("chapter_{0:D4}.html" -f ($i + 1))
                Title = $chapterTitle
                Html = $chapterHtml
            })
        }
    }
    else {
        $sections.Add([pscustomobject]@{
            File = "story.html"
            Title = $title
            Html = $body
        })
    }

    $tempEpub = "$DestPath.tmp"
    Remove-Item -LiteralPath $tempEpub -ErrorAction SilentlyContinue

    $fileStream = [System.IO.File]::Open($tempEpub, [System.IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Write-ZipTextEntry -Zip $zip -Name "mimetype" -Content "application/epub+zip" -CompressionLevel ([System.IO.Compression.CompressionLevel]::NoCompression)
        Write-ZipTextEntry -Zip $zip -Name "META-INF/container.xml" -Content @'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'@

        Write-ZipTextEntry -Zip $zip -Name "stylesheet.css" -Content @'
body { font-family: serif; line-height: 1.35; margin: 1em; }
h1, h2, h3 { page-break-after: avoid; }
blockquote { margin-left: 1em; margin-right: 1em; }
'@

        foreach ($section in $sections) {
            $sectionTitle = Escape-XmlText $section.Title
            $page = @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$sectionTitle</title>
  <link rel="stylesheet" type="text/css" href="stylesheet.css">
</head>
<body>
$($section.Html)
</body>
</html>
"@
            Write-ZipTextEntry -Zip $zip -Name $section.File -Content $page
        }

        $uid = [guid]::NewGuid().ToString()
        $manifestItems = New-Object System.Text.StringBuilder
        $spineItems = New-Object System.Text.StringBuilder
        [void]$manifestItems.AppendLine('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        [void]$manifestItems.AppendLine('    <item id="css" href="stylesheet.css" media-type="text/css"/>')
        for ($i = 0; $i -lt $sections.Count; $i++) {
            [void]$manifestItems.AppendLine(('    <item id="section{0}" href="{1}" media-type="text/html"/>' -f $i, (Escape-XmlText $sections[$i].File)))
            [void]$spineItems.AppendLine(('    <itemref idref="section{0}"/>' -f $i))
        }

        $escapedTitle = Escape-XmlText $title
        $escapedUrl = Escape-XmlText $WorkUrl
        $opf = @"
<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$escapedTitle</dc:title>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">$uid</dc:identifier>
    <dc:source>$escapedUrl</dc:source>
  </metadata>
  <manifest>
$manifestItems  </manifest>
  <spine toc="ncx">
$spineItems  </spine>
</package>
"@
        Write-ZipTextEntry -Zip $zip -Name "content.opf" -Content $opf

        $navPoints = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $sections.Count; $i++) {
            $playOrder = $i + 1
            $navTitle = Escape-XmlText $sections[$i].Title
            $navFile = Escape-XmlText $sections[$i].File
            [void]$navPoints.AppendLine(@"
    <navPoint id="navPoint-$playOrder" playOrder="$playOrder">
      <navLabel><text>$navTitle</text></navLabel>
      <content src="$navFile"/>
    </navPoint>
"@)
        }
        $ncx = @"
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="$uid"/>
  </head>
  <docTitle><text>$escapedTitle</text></docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>
"@
        Write-ZipTextEntry -Zip $zip -Name "toc.ncx" -Content $ncx
    }
    finally {
        $zip.Dispose()
        $fileStream.Close()
    }

    Move-Item -LiteralPath $tempEpub -Destination $DestPath -Force
}

function Get-EpubTitle {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($EpubPath)
    try {
        $opfEntry = $zip.Entries | Where-Object { $_.FullName -match '\.opf$' } | Select-Object -First 1
        if (-not $opfEntry) {
            return ""
        }

        $reader = New-Object System.IO.StreamReader($opfEntry.Open())
        try {
            $opf = $reader.ReadToEnd()
        }
        finally {
            $reader.Close()
        }

        $match = [regex]::Match($opf, '<dc:title[^>]*>(.*?)</dc:title>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($match.Success) {
            return [System.Net.WebUtility]::HtmlDecode(($match.Groups[1].Value -replace '<[^>]+>', '').Trim())
        }
    }
    finally {
        $zip.Dispose()
    }

    return ""
}

function Get-EpubChapterCount {
    param([string] $EpubPath)

    if ([string]::IsNullOrWhiteSpace($EpubPath) -or -not (Test-Path -LiteralPath $EpubPath)) {
        return 0
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($EpubPath)
    try {
        $opfEntry = $zip.Entries | Where-Object { $_.FullName -match '\.opf$' } | Select-Object -First 1
        if (-not $opfEntry) {
            return 0
        }

        $opfXml = ConvertTo-EpubXmlDocument -Content (Read-ZipEntryText -Entry $opfEntry) -EntryName $opfEntry.FullName
        $manifest = @{}
        foreach ($item in @($opfXml.SelectNodes("//*[local-name()='manifest']/*[local-name()='item']"))) {
            $manifest[$item.GetAttribute("id")] = [System.Uri]::UnescapeDataString($item.GetAttribute("href"))
        }

        $chapterCount = 0
        foreach ($itemref in @($opfXml.SelectNodes("//*[local-name()='spine']/*[local-name()='itemref']"))) {
            $idref = $itemref.GetAttribute("idref")
            if (-not $manifest.ContainsKey($idref)) {
                continue
            }
            $href = $manifest[$idref]
            if (($href -match $chapterFileRegex -or $href -match '(?i)(^|/)file\d+\.(xhtml|html)$') -and
                $href -notmatch $skipChapterFileRegex) {
                $chapterCount++
            }
        }
        if ($chapterCount -gt 0) {
            return $chapterCount
        }

        foreach ($entry in @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and
            $_.FullName -notmatch $skipChapterFileRegex -and
            $_.Length -gt 0
        })) {
            $content = Read-ZipEntryText -Entry $entry
            $heading = [regex]::Match($content, '(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>')
            if ($heading.Success -and (Get-PlainHtmlText $heading.Groups[1].Value) -match '^Chapter\s+\d+') {
                $chapterCount++
            }
        }
        return $chapterCount
    }
    finally {
        $zip.Dispose()
    }
}

function Test-FichubChapterAvailability {
    param(
        [string] $StoryUrl,
        [int] $AvailableChapters,
        [string] $ExistingEpubPath = "",
        [int] $KnownChapterCount = 0,
        [switch] $RequireKnownChapters,
        [switch] $RequireNewChapters
    )

    $requestedChapter = 0
    if ($StoryUrl -match '(?:fanfiction\.net|fictionpress\.com)/s/\d+/(?<chapter>\d+)') {
        $requestedChapter = [int]$Matches['chapter']
    }

    $existingChapterCount = 0
    if (-not [string]::IsNullOrWhiteSpace($ExistingEpubPath) -and (Test-Path -LiteralPath $ExistingEpubPath)) {
        $existingChapterCount = Get-EpubChapterCount -EpubPath $ExistingEpubPath
    }

    $minimumExpected = [Math]::Max($requestedChapter, [Math]::Max($existingChapterCount, $KnownChapterCount))
    $allowed = $AvailableChapters -ge $minimumExpected
    $message = "FicHub reports $AvailableChapters chapter(s)."
    if ($RequireKnownChapters -and $minimumExpected -eq 0) {
        $allowed = $false
        $message = "No verified AO3 chapter count is known; keeping this cached copy queued instead of opening an unverified book."
    }
    elseif (-not $allowed) {
        $message = "FicHub cache is incomplete: it reports $AvailableChapters chapter(s), but at least $minimumExpected are expected."
    }
    elseif ($RequireNewChapters -and $minimumExpected -gt 0 -and $AvailableChapters -le $minimumExpected) {
        $allowed = $false
        $message = "FicHub has no newer chapter count than the saved EPUB or chapter history ($minimumExpected); keeping the AO3 URL queued for retry."
    }

    return [pscustomobject]@{
        Allowed = $allowed
        AvailableChapters = $AvailableChapters
        RequestedChapter = $requestedChapter
        ExistingChapterCount = $existingChapterCount
        MinimumExpected = $minimumExpected
        Message = $message
    }
}

function Test-FichubSourceMatch {
    param([string] $RequestedUrl, [string] $CachedUrl)

    $requested = [regex]::Match($RequestedUrl, '^https?://archiveofourown\.org/works/(?<id>\d+)(?:[/?#]|$)')
    $cached = [regex]::Match($CachedUrl, '^https?://archiveofourown\.org/works/(?<id>\d+)(?:[/?#]|$)')
    return $requested.Success -and $cached.Success -and $requested.Groups['id'].Value -eq $cached.Groups['id'].Value
}

function Download-NativeAo3Epub {
    param([string] $WorkUrl)

    if ($WorkUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)') {
        Write-Status "Native AO3 fallback only supports work URLs, skipping: $WorkUrl"
        return $null
    }

    $workId = $Matches['id']
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $downloadUrl = "https://download.archiveofourown.org/downloads/$workId/work.epub?updated_at=$stamp"
    $tempFile = Join-Path $env:TEMP "ao3-native-$workId-$stamp.epub"

    Write-Status "Trying AO3 native EPUB download for work $workId."
    Write-Log "Native EPUB URL: $downloadUrl"

    $request = [System.Net.HttpWebRequest]::Create($downloadUrl)
    $request.UserAgent = $userAgent
    $request.Timeout = $nativeTimeoutMs
    $request.ReadWriteTimeout = $nativeTimeoutMs
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) {
            throw "AO3 native EPUB returned HTTP $([int]$response.StatusCode)."
        }

        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($tempFile)
        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Close()
            $inputStream.Close()
        }
    }
    finally {
        $response.Close()
    }

    $bytes = [System.IO.File]::ReadAllBytes($tempFile)
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        throw "AO3 native fallback did not return an EPUB file."
    }

    $title = Get-EpubTitle -EpubPath $tempFile
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "AO3-$workId"
    }

    $dest = Join-Path $stageDir "$(Get-SafeFileName $title).epub"
    Move-Item -LiteralPath $tempFile -Destination $dest -Force
    Write-Status "AO3 native EPUB downloaded: $(Split-Path -Leaf $dest)"
    return Get-Item -LiteralPath $dest
}

function Get-FileNameFromContentDisposition {
    param(
        [string] $HeaderValue,
        [string] $DefaultName
    )

    if ($HeaderValue -match 'filename\*=UTF-8''''([^;]+)') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }
    if ($HeaderValue -match 'filename="?([^";]+)"?') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }
    return $DefaultName
}

function Download-NativeAo3File {
    param([string] $WorkUrl)

    if ($WorkUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)') {
        Write-Status "Native AO3 download only supports work URLs, skipping: $WorkUrl"
        return $null
    }

    $workId = $Matches['id']
    $downloadStamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $downloadUrl = "https://download.archiveofourown.org/downloads/$workId/work.$downloadFormat`?updated_at=$downloadStamp"
    $tempFile = Join-Path $env:TEMP "ao3-native-$workId-$downloadStamp.$downloadFormat"

    Write-Status "Trying AO3 native $($downloadFormat.ToUpperInvariant()) download for work $workId."
    Write-Log "Native $($downloadFormat.ToUpperInvariant()) URL: $downloadUrl"

    $request = [System.Net.HttpWebRequest]::Create($downloadUrl)
    $request.UserAgent = $userAgent
    $request.Timeout = $nativeTimeoutMs
    $request.ReadWriteTimeout = $nativeTimeoutMs
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) {
            throw "AO3 native $downloadFormat returned HTTP $([int]$response.StatusCode)."
        }

        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($tempFile)
        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Close()
            $inputStream.Close()
        }

        $fileName = Get-FileNameFromContentDisposition -HeaderValue $response.Headers["Content-Disposition"] -DefaultName "AO3-$workId.$downloadFormat"
    }
    finally {
        $response.Close()
    }

    if ((Get-Item -LiteralPath $tempFile).Length -eq 0) {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        throw "AO3 native $downloadFormat returned an empty file."
    }

    if (-not $fileName.ToLowerInvariant().EndsWith(".$downloadFormat")) {
        $fileName = "$fileName.$downloadFormat"
    }
    $dest = Join-Path $stageDir (Get-SafeFileName $fileName)
    Move-Item -LiteralPath $tempFile -Destination $dest -Force
    Write-Status "AO3 native $($downloadFormat.ToUpperInvariant()) downloaded: $(Split-Path -Leaf $dest)"
    return Get-Item -LiteralPath $dest
}

function Download-FichubFile {
    param([string] $StoryUrl, [switch] $RequireNewChapters)

    if ($downloadFormat -notin @("epub", "html", "mobi", "pdf")) {
        throw "FicHub supports epub, html, mobi, and pdf output, not $downloadFormat."
    }

    $apiUrl = "https://fichub.net/api/v0/epub?q=$([System.Uri]::EscapeDataString($StoryUrl))"
    Write-Status "Checking FicHub for a cached copy."
    Write-Log "FicHub API URL: $apiUrl"

    try {
        $export = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = $fichubUserAgent } -TimeoutSec ([Math]::Max(120, $nativeTimeoutSeconds))
    }
    catch {
        throw "FicHub export request failed: $($_.Exception.Message)"
    }

    if ($null -eq $export -or [int]$export.err -ne 0) {
        $message = ""
        if ($export.msg) {
            $message = [string]$export.msg
        }
        elseif ($export.res) {
            $message = [string]$export.res
        }
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "unknown FicHub error"
        }
        throw "FicHub could not export this story: $message"
    }

    $isAo3Work = $StoryUrl -match '^https?://archiveofourown\.org/works/\d+'
    if ($isAo3Work -and -not (Test-FichubSourceMatch -RequestedUrl $StoryUrl -CachedUrl ([string]$export.meta.source))) {
        throw "FicHub did not confirm the same AO3 work ID; refusing a possibly different story."
    }

    $relativeDownloadUrl = $null
    if ($export.urls) {
        $property = $export.urls.PSObject.Properties[$downloadFormat]
        if ($property) {
            $relativeDownloadUrl = [string]$property.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($relativeDownloadUrl)) {
        throw "FicHub did not provide a $downloadFormat download URL for this story."
    }

    if ($relativeDownloadUrl -match '^https?://') {
        $downloadUrl = $relativeDownloadUrl
    }
    else {
        $downloadUrl = "https://fichub.net$relativeDownloadUrl"
    }

    $slug = [string]$export.slug
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = "fichub-download"
    }

    $metadataStoryTitle = ""
    if ($export.meta -and $export.meta.title) {
        $metadataStoryTitle = [string]$export.meta.title
    }
    $fichubChapterCount = 0
    if ($export.meta -and $null -ne $export.meta.chapters) {
        $fichubChapterCount = [int]$export.meta.chapters
    }
    if ($isAo3Work -and $fichubChapterCount -lt 1) {
        throw "FicHub did not report a chapter count for this AO3 work; refusing an unverified copy."
    }
    $existingEpubPath = ""
    if ($downloadFormat -eq "epub" -and -not [string]::IsNullOrWhiteSpace($metadataStoryTitle)) {
        $existingEpubPath = Join-Path $outDir "$(Get-SafeFileName $metadataStoryTitle).epub"
    }
    if ($isAo3Work -and -not [string]::IsNullOrWhiteSpace($existingEpubPath) -and
        (Test-Path -LiteralPath $existingEpubPath) -and
        (Get-EpubSourceUrl -EpubPath $existingEpubPath -CandidateUrls @($StoryUrl)) -ne $StoryUrl) {
        throw "A different or unidentified story already uses the FicHub output filename; refusing to replace it."
    }
    $knownChapterCount = if ($isAo3Work) { Get-KnownAo3ChapterCount -StoryUrl $StoryUrl } else { 0 }
    $availability = Test-FichubChapterAvailability -StoryUrl $StoryUrl -AvailableChapters $fichubChapterCount -ExistingEpubPath $existingEpubPath -KnownChapterCount $knownChapterCount -RequireKnownChapters:($isAo3Work -and -not $allowUnverifiedAo3Cache) -RequireNewChapters:$RequireNewChapters
    if (-not $availability.Allowed) {
        $storyLabel = if ($metadataStoryTitle) { "$metadataStoryTitle`: " } else { "" }
        Write-Status "$storyLabel$($availability.Message)"
        if ($RequireNewChapters -and $availability.MinimumExpected -gt 0 -and $availability.MinimumExpected -ge $fichubChapterCount) {
            return $null
        }
        throw $availability.Message
    }
    if ($isAo3Work) {
        $cacheDate = if ($export.meta.updated) { ([datetime]$export.meta.updated).ToString('yyyy-MM-dd') } else { 'unknown' }
        Write-Status "FicHub has $metadataStoryTitle ($fichubChapterCount chapters; cache dated $cacheDate). Current AO3 chapter count cannot be verified."
    }

    $temporaryFileName = "$(Get-SafeFileName $slug).$downloadFormat"
    $tempFile = Join-Path $env:TEMP "fichub-$stamp-$temporaryFileName"

    Write-Log "FicHub download URL: $downloadUrl"
    try {
        Invoke-WebRequest -Uri $downloadUrl -Headers @{ "User-Agent" = $fichubUserAgent } -OutFile $tempFile -TimeoutSec ([Math]::Max(180, $nativeTimeoutSeconds))
    }
    catch {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        throw "FicHub file download failed: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $tempFile) -or (Get-Item -LiteralPath $tempFile).Length -eq 0) {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        throw "FicHub returned an empty $downloadFormat file."
    }

    $storyTitle = ""
    if ($downloadFormat -eq "epub") {
        $storyTitle = Get-EpubTitle -EpubPath $tempFile
    }
    if ([string]::IsNullOrWhiteSpace($storyTitle) -and $export.title) {
        $storyTitle = [string]$export.title
    }
    if ([string]::IsNullOrWhiteSpace($storyTitle)) {
        $storyTitle = $slug
    }

    if ($downloadFormat -eq "epub") {
        $downloadedChapterCount = Get-EpubChapterCount -EpubPath $tempFile
        $requiredChapterCount = [Math]::Max($availability.MinimumExpected, $fichubChapterCount)
        if ($downloadedChapterCount -lt $requiredChapterCount) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            throw "FicHub EPUB is incomplete: it contains $downloadedChapterCount chapter(s), but $requiredChapterCount are expected."
        }
        if ($isAo3Work -and (Get-EpubSourceUrl -EpubPath $tempFile -CandidateUrls @($StoryUrl)) -ne $StoryUrl) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            throw "FicHub EPUB does not identify the requested AO3 work; refusing a possibly different story."
        }
    }
    $fileName = "$(Get-SafeFileName $storyTitle).$downloadFormat"
    $dest = Join-Path $stageDir $fileName

    Move-Item -LiteralPath $tempFile -Destination $dest -Force
    Write-Status "FicHub downloaded: $(Split-Path -Leaf $dest)"
    return Get-Item -LiteralPath $dest
}

function Download-NativeAo3HtmlAsEpub {
    param([string] $WorkUrl)

    if ($WorkUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)') {
        Write-Status "Native AO3 HTML fallback only supports work URLs, skipping: $WorkUrl"
        return $null
    }

    $workId = $Matches['id']
    $htmlStamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $downloadUrl = "https://download.archiveofourown.org/downloads/$workId/work.html?updated_at=$htmlStamp"
    $tempHtml = Join-Path $env:TEMP "ao3-native-$workId-$htmlStamp.html"

    Write-Status "Trying AO3 native HTML fallback for work $workId."
    Write-Log "Native HTML URL: $downloadUrl"

    $request = [System.Net.HttpWebRequest]::Create($downloadUrl)
    $request.UserAgent = $userAgent
    $request.Timeout = [Math]::Max($nativeTimeoutMs, 180000)
    $request.ReadWriteTimeout = [Math]::Max($nativeTimeoutMs, 180000)
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) {
            throw "AO3 native HTML returned HTTP $([int]$response.StatusCode)."
        }

        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($tempHtml)
        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Close()
            $inputStream.Close()
        }
    }
    finally {
        $response.Close()
    }

    $html = [System.IO.File]::ReadAllText($tempHtml, [System.Text.Encoding]::UTF8)
    if ($html -notmatch '<html' -or $html -notmatch '<div id="chapters"') {
        Remove-Item -LiteralPath $tempHtml -ErrorAction SilentlyContinue
        throw "AO3 native HTML fallback did not return a complete story page."
    }

    $titleMatch = [regex]::Match($html, '<h1[^>]*>(.*?)</h1>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $title = Get-PlainHtmlText $titleMatch.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "AO3-$workId"
    }

    $dest = Join-Path $stageDir "$(Get-SafeFileName $title).epub"
    Convert-Ao3HtmlDownloadToEpub -HtmlPath $tempHtml -WorkUrl $WorkUrl -DestPath $dest
    Remove-Item -LiteralPath $tempHtml -ErrorAction SilentlyContinue
    Write-Status "AO3 native HTML fallback built EPUB: $(Split-Path -Leaf $dest)"
    return Get-Item -LiteralPath $dest
}

function Invoke-NativeAo3Download {
    param([string] $WorkUrl)

    if ($downloadFormat -ne "epub") {
        try {
            return Download-NativeAo3File -WorkUrl $WorkUrl
        }
        catch {
            Write-Log "AO3 native $downloadFormat failed for $WorkUrl`: $($_.Exception.Message)"
            Write-Status "AO3 native $($downloadFormat.ToUpperInvariant()) was unavailable."
            return $null
        }
    }

    try {
        return Download-NativeAo3Epub -WorkUrl $WorkUrl
    }
    catch {
        Write-Log "AO3 native EPUB failed for $WorkUrl`: $($_.Exception.Message)"
        $httpStatus = Get-HttpStatusCode -ErrorException $_.Exception
        if ($httpStatus -gt 0) {
            Write-Status "AO3 native EPUB returned HTTP $httpStatus."
        }
        if (-not $fallbackHtmlToEpub) {
            Write-Status "AO3 native EPUB was unavailable."
            return $null
        }
        Write-Status "AO3 native EPUB was unavailable; trying AO3 HTML."
        try {
            return Download-NativeAo3HtmlAsEpub -WorkUrl $WorkUrl
        }
        catch {
            Write-Log "AO3 native HTML fallback failed for $WorkUrl`: $($_.Exception.Message)"
            $httpStatus = Get-HttpStatusCode -ErrorException $_.Exception
            if ($httpStatus -gt 0) {
                Write-Status "AO3 native HTML returned HTTP $httpStatus."
            }
            Write-Status "AO3 native HTML was unavailable."
            return $null
        }
    }
}

function Quote-ProcessArgument {
    param([string] $Value)
    '"' + ($Value -replace '"', '\"') + '"'
}

function Quote-CmdArgument {
    param([string] $Value)
    '"' + ($Value -replace '"', '""') + '"'
}

function Get-AllUrls {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $trimChars = @([char]32, [char]9, [char]13, [char]10, [char]34, [char]39, [char]41, [char]93, [char]125, [char]46, [char]44)
    return @([regex]::Matches($Text, 'https?://\S+') | ForEach-Object {
        $_.Value.Trim($trimChars)
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
}

function Test-Ao3Url {
    param([string] $Value)
    return $Value -match '^https?://archiveofourown\.org/(works|series)/\d+'
}

function Test-FanFictionUrl {
    param([string] $Value)
    return $Value -match '^https?://(?:www\.)?(fanfiction\.net|fictionpress\.com)/s/\d+'
}

function Test-SupportedUrl {
    param([string] $Value)
    return (Test-Ao3Url $Value) -or (Test-FanFictionUrl $Value)
}

function Convert-ToDownloadUrl {
    param([string] $Value)

    if ($Value -match "^(https?://archiveofourown\.org/works/\d+)/chapters/\d+") {
        return $Matches[1]
    }

    if ($Value -match "^(https?://archiveofourown\.org/works/\d+)") {
        return $Matches[1]
    }

    if ($Value -match "^(https?://archiveofourown\.org/series/\d+)") {
        return $Matches[1]
    }

    if ($Value -match "^(https?://(?:www\.)?(?:fanfiction\.net|fictionpress\.com)/s/\d+(?:/\d+)?(?:/[^/?#]+)?)") {
        return $Matches[1]
    }

    return $Value
}

function Get-StoryDisplayName {
    param([string] $Value)

    $normalizedUrl = Convert-ToDownloadUrl $Value
    if ($normalizedUrl -match '^https?://(?:www\.)?(?:fanfiction\.net|fictionpress\.com)/s/\d+(?:/\d+)?/(?<slug>[^/?#]+)') {
        $name = [System.Uri]::UnescapeDataString($Matches['slug']) -replace '-', ' '
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name.Trim()
        }
    }
    if ($normalizedUrl -match '^https?://archiveofourown\.org/(?<kind>works|series)/(?<id>\d+)') {
        $kind = if ($Matches['kind'] -eq 'series') { 'series' } else { 'work' }
        return "AO3 $kind $($Matches['id'])"
    }
    if ($normalizedUrl -match '^https?://(?:www\.)?(?<site>fanfiction\.net|fictionpress\.com)/s/(?<id>\d+)') {
        $siteName = if ($Matches['site'] -eq 'fictionpress.com') { 'FictionPress story' } else { 'FanFiction.net story' }
        return "$siteName $($Matches['id'])"
    }
    return 'Story'
}

function Get-DownloadStoryKey {
    param([string] $Value)

    $normalizedUrl = Convert-ToDownloadUrl $Value
    if ($normalizedUrl -match '^https?://archiveofourown\.org/(?<kind>works|series)/(?<id>\d+)') {
        return "archiveofourown.org/$($Matches['kind'].ToLowerInvariant())/$($Matches['id'])"
    }
    if ($normalizedUrl -match '^https?://(?:www\.)?(?<site>fanfiction\.net|fictionpress\.com)/s/(?<id>\d+)') {
        return "$($Matches['site'].ToLowerInvariant())/s/$($Matches['id'])"
    }
    return $normalizedUrl.ToLowerInvariant()
}

function Get-FanFictionChapterNumber {
    param([string] $Value)

    $normalizedUrl = Convert-ToDownloadUrl $Value
    if ($normalizedUrl -match '^https?://(?:www\.)?(?:fanfiction\.net|fictionpress\.com)/s/\d+/(?<chapter>\d+)(?:/|$)') {
        return [int]$Matches['chapter']
    }
    return 0
}

function Select-PreferredDownloadUrls {
    param([string[]] $Urls)

    $indexByStory = @{}
    $uniqueUrls = New-Object System.Collections.Generic.List[string]
    foreach ($url in @($Urls)) {
        if ([string]::IsNullOrWhiteSpace($url) -or -not (Test-SupportedUrl $url)) {
            continue
        }

        $normalizedUrl = Convert-ToDownloadUrl $url
        $storyKey = Get-DownloadStoryKey $normalizedUrl
        if (-not $indexByStory.ContainsKey($storyKey)) {
            $indexByStory[$storyKey] = $uniqueUrls.Count
            $uniqueUrls.Add($normalizedUrl) | Out-Null
            continue
        }

        $existingIndex = [int]$indexByStory[$storyKey]
        $existingChapter = Get-FanFictionChapterNumber $uniqueUrls[$existingIndex]
        $candidateChapter = Get-FanFictionChapterNumber $normalizedUrl
        if ($candidateChapter -gt $existingChapter) {
            $uniqueUrls[$existingIndex] = $normalizedUrl
        }
    }

    return @($uniqueUrls)
}

function Get-SupportedDownloadUrls {
    param([string] $Text)

    $downloadUrls = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in Get-AllUrls $Text) {
        if (-not (Test-SupportedUrl $candidate)) {
            continue
        }
        $downloadUrls.Add((Convert-ToDownloadUrl $candidate)) | Out-Null
    }

    return @(Select-PreferredDownloadUrls -Urls $downloadUrls)
}

function Merge-SupportedDownloadUrls {
    param(
        [string[]] $PrimaryUrls = @(),
        [string[]] $AdditionalUrls = @()
    )

    $combinedText = (@($PrimaryUrls) + @($AdditionalUrls)) -join [Environment]::NewLine
    return @(Get-SupportedDownloadUrls $combinedText)
}

function Invoke-FanFicFareDownload {
    param(
        [string[]] $DownloadUrls,
        [string] $Attempt,
        [string[]] $ExtraConfigPaths = @()
    )

    $stdoutFile = Join-Path $env:TEMP "fanficfare-$stamp-attempt-$Attempt.out"
    $stderrFile = Join-Path $env:TEMP "fanficfare-$stamp-attempt-$Attempt.err"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $fanficfareArgs = @(
        (Quote-CmdArgument $fff),
        "--format=$downloadFormat",
        "--force",
        "--config",
        (Quote-CmdArgument $config)
    )
    foreach ($extraConfig in $ExtraConfigPaths) {
        if (-not [string]::IsNullOrWhiteSpace($extraConfig)) {
            $fanficfareArgs += @("--config", (Quote-CmdArgument $extraConfig))
        }
    }
    $fanficfareArgs += ($DownloadUrls | ForEach-Object { Quote-CmdArgument $_ })
    $cmdLine = [string]::Join(" ", $fanficfareArgs) + " > " + (Quote-CmdArgument $stdoutFile) + " 2> " + (Quote-CmdArgument $stderrFile)
    $psi.Arguments = "/d /s /c `"$cmdLine`""
    $psi.WorkingDirectory = $outDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $downloadStarted = Get-Date
    $timedOut = $false
    $maxAttemptSeconds = 240
    while (-not $process.WaitForExit(10000)) {
        $elapsed = [int]((Get-Date) - $downloadStarted).TotalSeconds
        if ($showWaitMessages) {
            Write-Status "Still waiting for FanFicFare... $elapsed seconds elapsed. AO3 may be slow, blocking login, or timing out."
        }
        if ($elapsed -ge $maxAttemptSeconds) {
            $timedOut = $true
            Write-Status "FanFicFare has not returned after $maxAttemptSeconds seconds. Stopping this attempt."
            Stop-ProcessTree -ProcessId $process.Id
            break
        }
    }

    $stdout = ""
    $stderr = ""
    if (Test-Path -LiteralPath $stdoutFile) {
        $stdout = Get-Content -LiteralPath $stdoutFile -Raw
        Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stderrFile) {
        $stderr = Get-Content -LiteralPath $stderrFile -Raw
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }

    if ($stdout) {
        $stdout | Out-File -LiteralPath $logFile -Append -Encoding utf8
    }
    if ($stderr) {
        $stderr | Out-File -LiteralPath $logFile -Append -Encoding utf8
    }

    return [pscustomobject]@{
        ExitCode = if ($timedOut) { 124 } else { $process.ExitCode }
        Stdout = $stdout
        Stderr = $stderr
        TimedOut = $timedOut
    }
}

function ConvertFrom-SecureStringToPlainText {
    param([securestring] $SecureValue)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function New-TemporaryAo3LoginConfig {
    param(
        [string] $Username,
        [string] $Password
    )

    $tempConfig = Join-Path $env:TEMP "fanficfare-ao3-login-$stamp.ini"
    $content = @(
        "[archiveofourown.org]",
        "username:$Username",
        "password:$Password"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($tempConfig, $content, [System.Text.UTF8Encoding]::new($false))
    return $tempConfig
}

function New-TemporaryFanFicFareRuntimeConfig {
    $tempConfig = Join-Path $env:TEMP "fanficfare-ao3-runtime-$stamp.ini"
    $outputPattern = Join-Path $stageDir '${title}${formatext}'
    $content = @(
        "[defaults]",
        "output_filename:$outputPattern",
        "",
        "[archiveofourown.org]",
        "user_agent:$userAgent"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($tempConfig, $content, [System.Text.UTF8Encoding]::new($false))
    return $tempConfig
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Invoke-EpubPreparationSteps {
    param([string] $EpubPath)

    $timings = [ordered]@{}
    $runStep = {
        param(
            [string] $Name,
            [scriptblock] $Action
        )

        Write-Host "  $Name..."
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $Action
        $stopwatch.Stop()
        $timings[$Name] = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        Write-Host "  $Name finished in $($timings[$Name]) second(s)."
        return $result
    }

    $null = & $runStep "Normalizing XML declarations" { Repair-EpubXmlDeclarationWhitespace -EpubPath $EpubPath }
    if ($removeAfterword) {
        $null = & $runStep "Removing AO3 afterword" { Remove-Ao3AfterwordFromEpub -EpubPath $EpubPath }
    }
    if ($removeChapterNotes) {
        $null = & $runStep "Removing chapter notes" { Remove-Ao3ChapterNotesFromEpub -EpubPath $EpubPath }
    }
    if ($removeSeparatorLines) {
        $null = & $runStep "Removing separator-only lines" { Remove-SeparatorLinesFromEpub -EpubPath $EpubPath }
    }
    $null = & $runStep "Normalizing chapter headings" { Normalize-EpubChapterHeadings -EpubPath $EpubPath }
    if ($applyOldTemplateStyle) {
        $null = & $runStep "Applying template style" { Apply-OldTemplateStyleToEpub -EpubPath $EpubPath }
    }
    if ($makeStoryUrlClickable) {
        $null = & $runStep "Making story URL clickable" { Convert-StoryUrlToLink -EpubPath $EpubPath }
    }

    $validation = & $runStep "Validating EPUB" { Test-EpubIntegrity -EpubPath $EpubPath }
    if (-not $validation.Valid) {
        throw "EPUB validation failed: $($validation.Message)"
    }

    return [pscustomobject]@{
        Success = $true
        Message = $validation.Message
        Timings = $timings
        EntryCount = $validation.EntryCount
    }
}

function Invoke-EpubPreparationWorker {
    param([string] $EpubPath)

    $resultPath = Join-Path $stageDir ("prepare-result-" + [guid]::NewGuid().ToString("N") + ".json")
    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $scriptFile),
        "-PrepareOnly",
        "-PrepareInput", (Quote-ProcessArgument $EpubPath),
        "-PrepareResult", (Quote-ProcessArgument $resultPath)
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $psi.Arguments = [string]::Join(" ", $arguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $startedPreparing = Get-Date
    $timedOut = $false
    $lastProgressSecond = 0
    while (-not $process.WaitForExit(1000)) {
        $elapsed = [int]((Get-Date) - $startedPreparing).TotalSeconds
        if ($elapsed - $lastProgressSecond -ge 15) {
            Write-Status "Still preparing $([System.IO.Path]::GetFileName($EpubPath))... $elapsed seconds elapsed."
            $lastProgressSecond = $elapsed
        }
        if ($elapsed -ge $preparationTimeoutSeconds) {
            $timedOut = $true
            Stop-ProcessTree -ProcessId $process.Id
            break
        }
    }

    if ($timedOut) {
        $null = $process.WaitForExit(5000)
        Remove-DownloaderStagesForProcessId -ProcessId $process.Id
        Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Success = $false
            TimedOut = $true
            Message = "EPUB preparation exceeded the $preparationTimeoutSeconds second timeout."
        }
    }

    if (-not (Test-Path -LiteralPath $resultPath)) {
        return [pscustomobject]@{
            Success = $false
            TimedOut = $false
            Message = "EPUB preparation worker exited with code $($process.ExitCode) without returning a result."
        }
    }

    try {
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        return $result
    }
    finally {
        Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
    }
}

function Publish-PreparedFile {
    param(
        [string] $SourcePath,
        [string] $DestinationPath
    )

    $destinationDir = Split-Path -Parent $DestinationPath
    $publishId = "$PID-" + [guid]::NewGuid().ToString("N")
    $incomingName = "." + [System.IO.Path]::GetFileName($DestinationPath) + ".ao3-$publishId.tmp"
    $incomingPath = Join-Path $destinationDir $incomingName
    $backupPath = "$DestinationPath.ao3-backup-$publishId"
    Copy-Item -LiteralPath $SourcePath -Destination $incomingPath -Force -ErrorAction Stop

    if ([System.IO.Path]::GetExtension($DestinationPath).ToLowerInvariant() -eq ".epub") {
        $copiedValidation = Test-EpubIntegrity -EpubPath $incomingPath
        if (-not $copiedValidation.Valid) {
            Remove-Item -LiteralPath $incomingPath -Force -ErrorAction SilentlyContinue
            throw "Copied EPUB failed final validation: $($copiedValidation.Message)"
        }
    }

    $deadline = (Get-Date).AddSeconds($publishRetrySeconds)
    $lastMessageAt = -1
    try {
        while ($true) {
            try {
                if (Test-Path -LiteralPath $DestinationPath) {
                    [System.IO.File]::Replace($incomingPath, $DestinationPath, $backupPath, $true)
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                }
                else {
                    [System.IO.File]::Move($incomingPath, $DestinationPath)
                }
                Remove-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
                return Get-Item -LiteralPath $DestinationPath
            }
            catch {
                $remaining = [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
                if ($remaining -le 0) {
                    throw "Could not publish file after $publishRetrySeconds second(s): $($_.Exception.Message)"
                }
                if ($remaining -ne $lastMessageAt -and ($remaining % 5 -eq 0 -or $lastMessageAt -lt 0)) {
                    Write-Status "Destination is temporarily locked; retrying for up to $remaining more second(s)."
                    $lastMessageAt = $remaining
                }
                Start-Sleep -Seconds 1
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $incomingPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-EpubSourceUrl {
    param(
        [string] $EpubPath,
        [string[]] $CandidateUrls
    )

    if ([System.IO.Path]::GetExtension($EpubPath).ToLowerInvariant() -ne ".epub") {
        return $null
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $candidateByKey = @{}
    foreach ($candidate in $CandidateUrls) {
        if ($candidate -match 'archiveofourown\.org/works/(\d+)') {
            $candidateByKey["ao3:$($Matches[1])"] = $candidate
        }
        elseif ($candidate -match '(?:fanfiction\.net|fictionpress\.com)/s/(\d+)') {
            $candidateByKey["ff:$($Matches[1])"] = $candidate
        }
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($EpubPath)
    try {
        foreach ($entry in @($zip.Entries | Where-Object {
            $_.FullName -match '\.(opf|ncx|xhtml|html)$' -and $_.Length -gt 0
        })) {
            $content = Read-ZipEntryText -Entry $entry
            foreach ($match in [regex]::Matches($content, 'archiveofourown\.org/works/(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $key = "ao3:$($match.Groups[1].Value)"
                if ($candidateByKey.ContainsKey($key)) {
                    return $candidateByKey[$key]
                }
            }
            foreach ($match in [regex]::Matches($content, '(?:fanfiction\.net|fictionpress\.com)/s/(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $key = "ff:$($match.Groups[1].Value)"
                if ($candidateByKey.ContainsKey($key)) {
                    return $candidateByKey[$key]
                }
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    return $null
}

function Get-Ao3BrowserEpubCandidate {
    param(
        [string] $WorkUrl,
        [string] $Folder,
        [int] $KnownChapterCount,
        [string] $OutputFolder = ''
    )

    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return $null
    }

    foreach ($epub in @(Get-ChildItem -LiteralPath $Folder -Filter '*.epub' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)) {
        try {
            if ($WorkUrl -notmatch '^https?://archiveofourown\.org/works/(?<id>\d+)') {
                return $null
            }
            $requestedId = $Matches['id']
            if ((Get-Ao3EpubOriginWorkId -EpubPath $epub.FullName) -ne $requestedId) {
                continue
            }
            $chapterCount = Get-EpubChapterCount -EpubPath $epub.FullName
            if ($chapterCount -le $KnownChapterCount) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($OutputFolder)) {
                $title = Get-EpubTitle -EpubPath $epub.FullName
                if ([string]::IsNullOrWhiteSpace($title)) {
                    continue
                }
                $existingPath = Join-Path $OutputFolder "$(Get-SafeFileName $title).epub"
                if (Test-Path -LiteralPath $existingPath) {
                    if ((Get-Ao3EpubOriginWorkId -EpubPath $existingPath) -ne $requestedId -or
                        $chapterCount -le (Get-EpubChapterCount -EpubPath $existingPath)) {
                        continue
                    }
                }
            }
            return $epub
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-Ao3EpubOriginWorkId {
    param([string] $EpubPath)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($EpubPath)
    try {
        foreach ($entry in @($zip.Entries | Where-Object {
            $_.FullName -match '\.(xhtml|html)$' -and $_.Length -gt 0
        })) {
            $content = Read-ZipEntryText -Entry $entry
            $origin = [regex]::Match($content, '(?is)Posted\s+originally\s+on\b.{0,500}?Archive\s+of\s+Our\s+Own.{0,500}?\bat\s*<a\b[^>]*\bhref\s*=\s*["'']https://archiveofourown\.org/works/(?<id>\d+)(?:[/?#][^"'']*)?["'']')
            if ($origin.Success) {
                return $origin.Groups['id'].Value
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    return $null
}

$chapterHistoryReadOnly = $false
try {
    $chapterHistory = Read-Ao3ChapterHistory -Path $chapterHistoryFile
}
catch {
    $chapterHistory = @{}
    $chapterHistoryReadOnly = $true
    Write-Status "ERROR: AO3 chapter history could not be read. Cached AO3 copies without another verified chapter count will stay queued: $($_.Exception.Message)"
}

if ($PrepareOnly) {
    $workerResult = $null
    $workerExitCode = 0
    try {
        if ([string]::IsNullOrWhiteSpace($PrepareInput) -or -not (Test-Path -LiteralPath $PrepareInput)) {
            throw "Preparation input file was not found: $PrepareInput"
        }
        if ([string]::IsNullOrWhiteSpace($PrepareResult)) {
            throw "Preparation result path was not supplied."
        }
        $workerResult = Invoke-EpubPreparationSteps -EpubPath $PrepareInput
    }
    catch {
        $workerExitCode = 6
        $workerResult = [pscustomobject]@{
            Success = $false
            TimedOut = $false
            Message = $_.Exception.Message
        }
        Write-Host "  Preparation failed: $($_.Exception.Message)"
    }

    try {
        $json = $workerResult | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($PrepareResult, $json, [System.Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-DownloaderStage -Path $stageDir
    }
    exit $workerExitCode
}

if ($LibraryOnly) {
    return
}

Write-Status "Downloader started at $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log "App folder: `"$appDir`""
Write-Status "Output folder: `"$outDir`""

if (Invoke-StartupUpdateCheck) {
    Write-Status "Update installed; restarting the requested download."
    if ($stageDir -and (Test-Path -LiteralPath $stageDir)) {
        Remove-DownloaderStage -Path $stageDir
    }
    $restartArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptFile,
        "-SkipUpdateCheck"
    ) + @($UrlParts)
    & powershell.exe @restartArguments
    exit $LASTEXITCODE
}

$fanficfareAvailable = Test-Path -LiteralPath $fff
if ($fanficfareAvailable) {
    Write-Log "FanFicFare executable: `"$fff`""
}
else {
    Write-Log "FanFicFare executable not found at `"$fff`". FanFicFare backup is disabled."
    if (-not $preferNative) {
        Close-WithError 2 "ERROR: prefer_native is false, but FanFicFare was not found at `"$fff`""
    }
}

$inputText = ($UrlParts -join " ").Trim()
$urls = @()

if (-not [string]::IsNullOrWhiteSpace($inputText)) {
    $urls = @(Get-SupportedDownloadUrls $inputText)
    if ($urls.Count -gt 0) {
        Write-Status "Using $($urls.Count) supported URL(s) from command line."
    }
}

if ($urls.Count -eq 0 -and [string]::IsNullOrWhiteSpace($inputText) -and $readClipboard -and $autoStartClipboard) {
    try {
        $clipboardText = Get-Clipboard -Raw
        $urls = @(Get-SupportedDownloadUrls $clipboardText)
        if ($urls.Count -gt 0) {
            Write-Status "Using $($urls.Count) supported URL(s) from clipboard."
        }
        elseif ((Get-AllUrls $clipboardText).Count -gt 0) {
            Write-Status "Clipboard contains URL(s), but no supported links, so it was not auto-started."
        }
    }
    catch {
        Write-Log "Clipboard check failed: $($_.Exception.Message)"
    }
}

$queuedFailedUrls = @(Read-FailedUrlQueue)
if ($retryFailedUrls -and $queuedFailedUrls.Count -gt 0) {
    $freshUrlCount = $urls.Count
    $freshStoryKeys = @{}
    foreach ($freshUrl in $urls) {
        $freshStoryKeys[(Get-DownloadStoryKey $freshUrl)] = $true
    }
    $matchingQueuedStoryCount = @($queuedFailedUrls | Where-Object {
        $freshStoryKeys.ContainsKey((Get-DownloadStoryKey $_))
    }).Count
    $urls = @(Merge-SupportedDownloadUrls -PrimaryUrls $urls -AdditionalUrls $queuedFailedUrls)
    if ($freshUrlCount -gt 0) {
        if ($matchingQueuedStoryCount -gt 0) {
            Write-Status "Merged $($queuedFailedUrls.Count) queued failed URL(s); $matchingQueuedStoryCount matched fic(s) already present and were not duplicated. Processing $($urls.Count) unique fic(s) in total."
        }
        else {
            Write-Status "Added $($queuedFailedUrls.Count) queued failed URL(s); processing $($urls.Count) unique fic(s) in total."
        }
    }
    else {
        Write-Status "No fresh supported URLs were found; retrying $($urls.Count) URL(s) from `"$failedUrlFile`"."
    }
}
elseif ($queuedFailedUrls.Count -gt 0) {
    Write-Log "$($queuedFailedUrls.Count) failed URL(s) remain queued in `"$failedUrlFile`"."
}

if ($urls.Count -eq 0) {
    Write-Host "Enter one or more AO3 or FanFiction.net work URLs, for example:"
    Write-Host "  https://archiveofourown.org/works/51222748"
    Write-Host "  https://www.fanfiction.net/s/14196398/1/Weaponized-Cuteness"
    Write-Host ""
    $promptInput = Read-Host "URL"
    if ($null -eq $promptInput) {
        $inputText = ""
    }
    else {
        $inputText = ([string]$promptInput).Trim()
    }
    $urls = @(Get-SupportedDownloadUrls $inputText)
    if ($urls.Count -gt 0) {
        Write-Status "Using $($urls.Count) supported URL(s) from prompt."
    }
}

if ($urls.Count -eq 0) {
    Close-WithError 2 "ERROR: No valid URL was entered."
}

Write-Status "Preparing to download $($urls.Count) fic(s)."
for ($urlIndex = 0; $urlIndex -lt $urls.Count; $urlIndex++) {
    $storyNumber = $urlIndex + 1
    Write-Host "Story $storyNumber of $($urls.Count): $(Get-StoryDisplayName $urls[$urlIndex])"
    Write-Log "URL $storyNumber of $($urls.Count): $($urls[$urlIndex])"
}

Write-Log ""
$fics = @()
$ficUrlByPath = @{}
$fanficfareUrls = @()
$importedUrls = @{}
if ($downloadFormat -eq 'epub' -and -not [string]::IsNullOrWhiteSpace($browserEpubFolder)) {
    Write-Status 'Checking browser-downloaded AO3 EPUBs.'
    foreach ($url in $urls) {
        if ($url -notmatch '^https?://archiveofourown\.org/works/\d+') {
            continue
        }
        $knownChapterCount = Get-KnownAo3ChapterCount -StoryUrl $url
        $browserEpub = Get-Ao3BrowserEpubCandidate -WorkUrl $url -Folder $browserEpubFolder -KnownChapterCount $knownChapterCount -OutputFolder $outDir
        if (-not $browserEpub) {
            continue
        }
        $stagedPath = $null
        $canCleanStage = $false
        try {
            $title = Get-EpubTitle -EpubPath $browserEpub.FullName
            if ([string]::IsNullOrWhiteSpace($title)) {
                throw 'Browser EPUB has no title.'
            }
            $stagedPath = Join-Path $stageDir "$(Get-SafeFileName $title).epub"
            if (Test-Path -LiteralPath $stagedPath) {
                throw "Another staged EPUB already uses the title $title."
            }
            $canCleanStage = $true
            Copy-Item -LiteralPath $browserEpub.FullName -Destination $stagedPath -ErrorAction Stop
            $importedFic = Get-Item -LiteralPath $stagedPath
            $fics += $importedFic
            $ficUrlByPath[$importedFic.FullName.ToLowerInvariant()] = $url
            $importedUrls[$url] = $true
            Write-Status "Using browser-downloaded EPUB: $title"
        }
        catch {
            if ($canCleanStage -and -not [string]::IsNullOrWhiteSpace($stagedPath)) {
                Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Browser EPUB import failed for $url`: $($_.Exception.Message)"
            Write-Status 'Browser EPUB could not be imported; trying the usual download routes.'
        }
    }
}
if ($preferNative) {
    Write-Status 'Trying native download routes for remaining fics.'
    foreach ($url in $urls) {
        if ($importedUrls.ContainsKey($url)) {
            continue
        }
        if ($url -match '^https?://archiveofourown\.org/works/\d+') {
            $nativeFic = Invoke-NativeAo3Download -WorkUrl $url
            if ($nativeFic) {
                $fics += $nativeFic
                $ficUrlByPath[$nativeFic.FullName.ToLowerInvariant()] = $url
            }
            else {
                if ($useFichub -and $useFichubForAo3 -and $downloadFormat -eq 'epub') {
                    try {
                        $cachedFic = Download-FichubFile -StoryUrl $url -RequireNewChapters
                        if ($cachedFic) {
                            $fics += $cachedFic
                            $ficUrlByPath[$cachedFic.FullName.ToLowerInvariant()] = $url
                            Write-Status "Saved FicHub's cached copy; keeping this AO3 work queued until a direct download verifies the latest chapters."
                        }
                        $failedUrls += $url
                    }
                    catch {
                        Write-Log "FicHub AO3 fallback failed for $url`: $($_.Exception.Message)"
                        Write-Status "FicHub could not provide a verified copy: $($_.Exception.Message)"
                        $fanficfareUrls += $url
                    }
                }
                else {
                    $fanficfareUrls += $url
                }
            }
        }
        else {
            if (Test-FanFictionUrl $url) {
                if (-not $useFichub) {
                    Write-Status "FicHub is disabled, so FanFiction.net URL cannot be downloaded."
                    $failedUrls += $url
                    continue
                }
                try {
                    $fichubFic = Download-FichubFile -StoryUrl $url
                    if ($fichubFic) {
                        $fics += $fichubFic
                        $ficUrlByPath[$fichubFic.FullName.ToLowerInvariant()] = $url
                    }
                    else {
                        $failedUrls += $url
                    }
                }
                catch {
                    Write-Log "FicHub failed for $url`: $($_.Exception.Message)"
                    Write-Status "FicHub could not download this FanFiction.net URL."
                    $failedUrls += $url
                }
                Start-Sleep -Seconds 2
            }
            else {
                $fanficfareUrls += $url
            }
        }
    }
}
else {
    Write-Status "Trying FanFicFare first."
    foreach ($url in $urls) {
        if ($importedUrls.ContainsKey($url)) {
            continue
        }
        if (Test-FanFictionUrl $url) {
            if (-not $useFichub) {
                Write-Status "FicHub is disabled, so FanFiction.net URL cannot be downloaded."
                $failedUrls += $url
                continue
            }
            try {
                $fichubFic = Download-FichubFile -StoryUrl $url
                if ($fichubFic) {
                    $fics += $fichubFic
                    $ficUrlByPath[$fichubFic.FullName.ToLowerInvariant()] = $url
                }
                else {
                    $failedUrls += $url
                }
            }
            catch {
                Write-Log "FicHub failed for $url`: $($_.Exception.Message)"
                Write-Status "FicHub could not download this FanFiction.net URL."
                $failedUrls += $url
            }
            Start-Sleep -Seconds 2
        }
        else {
            $fanficfareUrls += $url
        }
    }
}

if (@($fics).Count -gt 0) {
    Write-Status "Retrieved $(@($fics).Count) fic(s) before the FanFicFare backup."
}

if (@($fanficfareUrls).Count -gt 0) {
    if (-not $fanficfareAvailable) {
        $failedUrls += $fanficfareUrls
        Save-FailedUrls -Urls $failedUrls
        if (@($fics).Count -eq 0) {
            Close-WithError 2 "ERROR: AO3 native download could not handle the URL(s), and FanFicFare is not installed at `"$fff`"."
        }
        Write-Status "Some URL(s) need FanFicFare backup, but FanFicFare is not installed. Continuing with successful native downloads."
    }
    else {
    Write-Log ""
    Write-Status "Native download could not handle $(@($fanficfareUrls).Count) URL(s); trying FanFicFare backup."
    $runtimeFanficfareConfig = New-TemporaryFanFicFareRuntimeConfig

    Push-Location $appDir
    try {
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            if ($attempt -gt 1) {
                Write-Status "Retry attempt $attempt of $maxAttempts."
            }

            $result = Invoke-FanFicFareDownload -DownloadUrls $fanficfareUrls -Attempt $attempt -ExtraConfigPaths @($runtimeFanficfareConfig)
            $exitCode = $result.ExitCode
            $stdout = $result.Stdout
            $stderr = $result.Stderr

            $fanficfareReportedFailure = $stdout -match '(?m)\bFailed:' -or $stderr -match '(?m)\bFailed:'
            $fanficfareLoginFailed = Test-FanFicFareLoginFailure -Stdout $stdout -Stderr $stderr
            $ao3Server525 = $stdout -match '525 Server Error' -or $stderr -match '525 Server Error'
            if ($result.TimedOut) {
                break
            }
            if ($fanficfareLoginFailed) {
                Write-Status "AO3 requested login, but FanFicFare could not log in."
                break
            }
            if ($ao3Server525) {
                Write-Status "AO3 returned 525 in FanFicFare backup. Skipping further FanFicFare retries."
                break
            }
            if (-not $ao3Server525 -or ($exitCode -eq 0 -and -not $fanficfareReportedFailure) -or $attempt -eq $maxAttempts) {
                break
            }
        }
    }
    finally {
        Pop-Location
    }

    Write-Log ""
    Write-Status "FanFicFare backup finished with exit code $exitCode."
    Write-Log ""
    Write-Log "Log saved to: `"$logFile`""

    $fanficfareReportedFailure = $stdout -match '(?m)\bFailed:' -or $stderr -match '(?m)\bFailed:'
    $fanficfareLoginFailed = Test-FanFicFareLoginFailure -Stdout $stdout -Stderr $stderr
    if ($exitCode -ne 0 -or $fanficfareReportedFailure -or $fanficfareLoginFailed) {
        $failureCode = $exitCode
        if ($failureCode -eq 0) {
            $failureCode = 4
        }
        $combinedOutput = "$stdout`n$stderr"
        $reportedFailedUrls = @([regex]::Matches($combinedOutput, 'URL\((https?://[^)]+)\)\s+Failed') | ForEach-Object {
            $_.Groups[1].Value
        })
        if ($reportedFailedUrls.Count -gt 0) {
            $failedUrls += $reportedFailedUrls
        }
        elseif ($result.TimedOut -or $exitCode -ne 0 -or $fanficfareLoginFailed) {
            $failedUrls += $fanficfareUrls
        }

        if ($combinedOutput -match '525 Server Error') {
            Write-Status "FanFicFare backup also hit AO3 525."
        }
        if ($combinedOutput -match '403 Client Error: Forbidden for url: https://archiveofourown\.org/users/login') {
            Write-Status "AO3 says this work needs login. FanFicFare's first login attempt was blocked with 403 Forbidden."
            Write-Host "Enter AO3 login details to retry once, or leave username blank to cancel."
            $loginCancelled = $false
            $ao3UsernameInput = Read-Host "AO3 username"
            if ($null -eq $ao3UsernameInput) {
                $ao3Username = ""
            }
            else {
                $ao3Username = ([string]$ao3UsernameInput).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($ao3Username)) {
                $loginCancelled = $true
                $failedUrls += $fanficfareUrls
                if (@(Get-PotentialSuccessfulEpubs).Count -eq 0) {
                    Close-WithError $failureCode "ERROR: AO3 login was required, but no username was entered."
                }
                Write-Status "AO3 login was cancelled. Continuing with successful downloads."
            }

            if (-not $loginCancelled) {
                $securePassword = Read-Host "AO3 password" -AsSecureString
                $ao3Password = ConvertFrom-SecureStringToPlainText $securePassword
                if ([string]::IsNullOrWhiteSpace($ao3Password)) {
                    $loginCancelled = $true
                    $failedUrls += $fanficfareUrls
                    if (@(Get-PotentialSuccessfulEpubs).Count -eq 0) {
                        Close-WithError $failureCode "ERROR: AO3 login was required, but no password was entered."
                    }
                    Write-Status "AO3 login was cancelled. Continuing with successful downloads."
                }
            }

            if (-not $loginCancelled) {
                $loginConfig = New-TemporaryAo3LoginConfig -Username $ao3Username -Password $ao3Password
                try {
                    Write-Status "Retrying once with supplied AO3 login."
                    Push-Location $appDir
                    try {
                        $loginResult = Invoke-FanFicFareDownload -DownloadUrls $fanficfareUrls -Attempt "login" -ExtraConfigPaths @($runtimeFanficfareConfig, $loginConfig)
                    }
                    finally {
                        Pop-Location
                    }

                    $exitCode = $loginResult.ExitCode
                    $stdout = $loginResult.Stdout
                    $stderr = $loginResult.Stderr
                    Write-Status "FanFicFare login retry finished with exit code $exitCode."
                    $fanficfareReportedFailure = $stdout -match '(?m)\bFailed:' -or $stderr -match '(?m)\bFailed:'
                    if ($exitCode -eq 0 -and -not $fanficfareReportedFailure) {
                        $failedUrls = @($failedUrls | Where-Object { $_ -notin $fanficfareUrls })
                        Write-Status "AO3 login retry succeeded."
                    }
                    else {
                        $failedUrls += $fanficfareUrls
                        if (@(Get-PotentialSuccessfulEpubs).Count -eq 0) {
                            Close-WithError $failureCode "ERROR: AO3 login retry failed. AO3 may be blocking scripted login, or the work may be hidden/restricted in a way this downloader cannot access."
                        }
                        Write-Status "AO3 login retry failed. Continuing with successful downloads."
                    }
                }
                finally {
                    Remove-Item -LiteralPath $loginConfig -ErrorAction SilentlyContinue
                    $ao3Password = $null
                }
            }
        }
        if ($exitCode -eq 124) {
            Save-FailedUrls -Urls $failedUrls
            if (@(Get-PotentialSuccessfulEpubs).Count -eq 0) {
                Close-WithError $failureCode "ERROR: FanFicFare did not return after 4 minutes. AO3 may be stalling or blocking the request before it can report login-required. Try opening the work in your browser while logged into AO3, then run the downloader again."
            }
            Write-Status "FanFicFare timed out for some URLs. Continuing with successful downloads."
        }

        if ($exitCode -ne 0 -or $fanficfareReportedFailure -or $fanficfareLoginFailed) {
            Save-FailedUrls -Urls $failedUrls
            if (@(Get-PotentialSuccessfulEpubs).Count -eq 0) {
                if ($fanficfareLoginFailed) {
                    Close-WithError $failureCode "ERROR: AO3 requested login and FanFicFare could not complete it. The work remains queued for retry."
                }
                Close-WithError $failureCode "ERROR: Download failed. If AO3 shows a site challenge in Chrome, complete it, reload the story page once, then run this command again."
            }
            Write-Status "Some URLs failed. Continuing with successful downloads."
        }
    }
    Remove-Item -LiteralPath $runtimeFanficfareConfig -ErrorAction SilentlyContinue
    }
}

$stagedFics = @(Get-ChildItem -LiteralPath $stageDir -Filter "*.$downloadFormat" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
$fics = @($fics + $stagedFics | Where-Object { $_ } | Sort-Object FullName -Unique)
$downloadedCount = $fics.Count
if ($fics.Count -eq 0 -and @($failedUrls).Count -gt 0) {
    Save-FailedUrls -Urls $failedUrls
}

if ($fics.Count -gt 0) {
    Write-Status "Found $($fics.Count) new $downloadFormat file(s)."
    $preparedRecords = @()
    $preparationFailures = 0
    foreach ($fic in $fics) {
        Write-Status "Preparing file: $($fic.Name)"
        $sourceUrl = $null
        $preparedChapterCount = 0
        try {
            $workPath = $fic.FullName
            $sourceKey = $workPath.ToLowerInvariant()
            if ($ficUrlByPath.ContainsKey($sourceKey)) {
                $sourceUrl = $ficUrlByPath[$sourceKey]
            }
            elseif ([System.IO.Path]::GetExtension($workPath).ToLowerInvariant() -eq ".epub") {
                $sourceUrl = Get-EpubSourceUrl -EpubPath $workPath -CandidateUrls $urls
            }
            if ([string]::IsNullOrWhiteSpace($sourceUrl) -and $urls.Count -eq 1) {
                $sourceUrl = $urls[0]
            }

            $workDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $workPath)).TrimEnd('\')
            $stagingRoot = [System.IO.Path]::GetFullPath($stageDir).TrimEnd('\')
            if ($workDir -ine $stagingRoot) {
                $stagedPath = Join-Path $stageDir $fic.Name
                Copy-Item -LiteralPath $workPath -Destination $stagedPath -Force -ErrorAction Stop
                $workPath = $stagedPath
            }

            if ([System.IO.Path]::GetExtension($workPath).TrimStart(".").ToLowerInvariant() -eq "epub") {
                $preparationResult = Invoke-EpubPreparationWorker -EpubPath $workPath
                if (-not $preparationResult.Success) {
                    throw $preparationResult.Message
                }
                Write-Log "Prepared and validated `"$($fic.Name)`": $($preparationResult.Message)"
                if ($sourceUrl -match '^https?://archiveofourown\.org/works/\d+') {
                    $preparedChapterCount = Get-EpubChapterCount -EpubPath $workPath
                    $knownChapterCount = Get-KnownAo3ChapterCount -StoryUrl $sourceUrl
                    if ($preparedChapterCount -lt 1 -or $preparedChapterCount -lt $knownChapterCount) {
                        throw "AO3 EPUB has $preparedChapterCount chapter(s), but at least $knownChapterCount are known. Refusing to replace the previous complete copy."
                    }
                }
            }

            $finalPath = Join-Path $outDir $fic.Name
            $publishedFile = Publish-PreparedFile -SourcePath $workPath -DestinationPath $finalPath
            $preparedRecords += [pscustomobject]@{
                File = $publishedFile
                Url = $sourceUrl
            }
            if ($preparedChapterCount -gt 0 -and $sourceUrl -match '^https?://archiveofourown\.org/works/\d+') {
                try {
                    Record-Ao3ChapterCount -StoryUrl $sourceUrl -ChapterCount $preparedChapterCount
                }
                catch {
                    $hadErrors = $true
                    $failedUrls += $sourceUrl
                    Write-Status "ERROR: File was saved, but AO3 chapter history could not be updated: $($_.Exception.Message)"
                }
            }
            Write-Status "Saved file: $($fic.Name)"
        }
        catch {
            $hadErrors = $true
            $preparationFailures++
            if (-not [string]::IsNullOrWhiteSpace($sourceUrl)) {
                $failedUrls += $sourceUrl
            }
            Write-Status "ERROR: Could not prepare or save `"$($fic.Name)`": $($_.Exception.Message)"
            Write-Status "Continuing with the remaining files."
        }
    }
    $fics = @($preparedRecords | ForEach-Object { $_.File })

    $openedCount = 0
    $openFailures = 0
    if ($openAfterDownload) {
        foreach ($record in ($preparedRecords | Sort-Object { $_.File.LastWriteTime })) {
            $fic = $record.File
            Write-Status "Opening file: $($fic.Name)"
            try {
                if ([string]::IsNullOrWhiteSpace($readerPath)) {
                    Invoke-Item -LiteralPath $fic.FullName -ErrorAction Stop
                }
                else {
                    Start-Process -FilePath $readerPath -ArgumentList @($fic.FullName) -ErrorAction Stop
                }
                $openedCount++
            }
            catch {
                $hadErrors = $true
                $openFailures++
                Write-Status "ERROR: File was saved, but Windows could not open `"$($fic.FullName)`": $($_.Exception.Message)"
                Write-Status "Continuing with the remaining files."
            }
            Start-Sleep -Milliseconds 750
        }
    }

    if (@($failedUrls).Count -gt 0) {
        $hadErrors = $true
    }

    $failedKeys = @{}
    foreach ($failedUrl in @($failedUrls)) {
        if (-not [string]::IsNullOrWhiteSpace($failedUrl)) {
            $failedKeys[(Convert-ToDownloadUrl $failedUrl).ToLowerInvariant()] = $true
        }
    }
    $completedUrls = @($preparedRecords | ForEach-Object { $_.Url } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not $failedKeys.ContainsKey((Convert-ToDownloadUrl $_).ToLowerInvariant())
    } | Select-Object -Unique)
    Remove-CompletedFailedUrls -Urls $completedUrls
    if (@($failedUrls).Count -gt 0) {
        Save-FailedUrls -Urls $failedUrls
    }
    $failedUrlCount = @(Read-FailedUrlQueue).Count

    Write-Status ""
    Write-Status "Run summary:"
    Write-Status "  URLs received: $($urls.Count)"
    Write-Status "  Files retrieved: $downloadedCount"
    Write-Status "  Files prepared and saved: $($preparedRecords.Count)"
    if ($openAfterDownload) {
        Write-Status "  Files opened: $openedCount"
    }
    else {
        Write-Status "  Files opened: disabled"
    }
    Write-Status "  Preparation or save failures: $preparationFailures"
    Write-Status "  Reader launch failures: $openFailures"
    Write-Status "  URLs still queued for retry: $failedUrlCount"

    if (-not $hadErrors) {
        Write-Status "Done. Successful run; removing log."
        Remove-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
    }
    else {
        Write-Status "Done with errors. Log saved to: `"$logFile`""
        if ($failedUrlCount -gt 0) {
            Write-Status "Retry failed URLs from: `"$failedUrlFile`""
        }
    }
    Remove-DownloaderStage -Path $stageDir
    if ($hadErrors -and $pauseOnError) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
    if ($hadErrors) {
        exit 6
    }
    exit 0
}
else {
    if (@($failedUrls).Count -gt 0) {
        Close-WithError 4 "ERROR: No new $downloadFormat file was saved. $(@($failedUrls).Count) URL(s) remain queued in `"$failedUrlFile`"; see the status above for the reason."
    }
    Close-WithError 4 "ERROR: Download finished, but no new .$downloadFormat file was found in `"$outDir`"."
}
