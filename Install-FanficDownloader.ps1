[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$appDirectory = $PSScriptRoot
$userDirectory = Join-Path $appDirectory "user"
$logDirectory = Join-Path $userDirectory "logs"
$runtimeDirectory = Join-Path $appDirectory "fanficfare_env"
$requirementsPath = Join-Path $appDirectory "requirements.txt"

New-Item -ItemType Directory -Force -Path $userDirectory, $logDirectory | Out-Null
$logPath = Join-Path $logDirectory ("install-" + (Get-Date -Format "yyyy-MM-dd_HHmmss") + ".log")

function Write-InstallStatus {
    param([string] $Message)
    Write-Host $Message
    $Message | Out-File -LiteralPath $logPath -Append -Encoding utf8
}

function Copy-ExampleWhenMissing {
    param(
        [string] $ExampleName,
        [string] $UserName
    )

    $source = Join-Path $appDirectory $ExampleName
    $destination = Join-Path $userDirectory $UserName
    if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $destination
        Write-InstallStatus "Created user\$UserName from the supplied example."
    }
}

function Get-PythonCommand {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        & $launcher.Source -3 -c "import sys; assert sys.version_info >= (3, 10)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ File = $launcher.Source; Arguments = @("-3") }
        }
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source -c "import sys; assert sys.version_info >= (3, 10)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ File = $python.Source; Arguments = @() }
        }
    }
    throw "Python 3.10 or later was not found. Install Python, then run this installer again."
}

try {
    Write-InstallStatus "Fanfic Downloader installation started."
    Copy-ExampleWhenMissing -ExampleName "downloader.example.ini" -UserName "downloader.ini"
    Copy-ExampleWhenMissing -ExampleName "fanficfare.example.ini" -UserName "fanficfare_personal.ini"

    if (-not (Test-Path -LiteralPath (Join-Path $runtimeDirectory "Scripts\fanficfare.exe"))) {
        if (-not (Test-Path -LiteralPath $requirementsPath)) {
            throw "requirements.txt is missing from the program folder."
        }
        $python = Get-PythonCommand
        Write-InstallStatus "Creating the private FanFicFare Python environment."
        & $python.File @($python.Arguments) -m venv $runtimeDirectory 2>&1 | Out-File -LiteralPath $logPath -Append -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "Python could not create the FanFicFare environment."
        }
        $runtimePython = Join-Path $runtimeDirectory "Scripts\python.exe"
        Write-InstallStatus "Installing the tested FanFicFare dependencies."
        & $runtimePython -m pip install --disable-pip-version-check --requirement $requirementsPath 2>&1 | Out-File -LiteralPath $logPath -Append -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "FanFicFare dependencies could not be installed. See $logPath"
        }
    }
    else {
        Write-InstallStatus "The existing FanFicFare environment was preserved."
    }

    Write-InstallStatus "Installation completed. Run Download AO3 with FanFicFare.cmd to begin."
    exit 0
}
catch {
    Write-InstallStatus "Installation failed: $($_.Exception.Message)"
    exit 1
}
