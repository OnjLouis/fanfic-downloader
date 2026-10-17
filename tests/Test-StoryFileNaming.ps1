param([string] $ScratchParent = (Join-Path $env:TEMP 'fanfic-downloader-name-test'))

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Download AO3 with FanFicFare.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Downloader script has a parse error.' }
foreach ($name in @('Get-StoryKey', 'Test-StoryFilenameHistoryEntry', 'Read-StoryFilenameHistory', 'Save-StoryFilenameHistory', 'Get-StoryOutputFileName')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Get-EpubSourceUrl {
    param([string] $EpubPath, [string[]] $CandidateUrls)
    if ((Get-Content -LiteralPath $EpubPath -Raw) -match '^fixture') { return $CandidateUrls[0] }
    return $null
}

function Write-Log { param([string] $Message) }

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}

$scratchBase = [IO.Path]::GetFullPath($ScratchParent).TrimEnd('\')
$ScratchRoot = [IO.Path]::GetFullPath((Join-Path $scratchBase ('run-' + [guid]::NewGuid().ToString('N'))))
if (-not $ScratchRoot.StartsWith($scratchBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory escaped its parent.'
}
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
$output = Join-Path $ScratchRoot 'output'
New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
    $url = 'https://archiveofourown.org/works/91757466/chapters/1'
    $key = Get-StoryKey -StoryUrl $url
    Assert-Equal $key 'ao3:91757466'
    $historyPath = Join-Path $ScratchRoot 'filename-history.json'
    $history = @{}
    Assert-Equal (Get-StoryOutputFileName -StoryUrl $url -ProposedName 'New Title.epub' -OutputFolder $output -FilenameHistory $history) 'New Title.epub'

    Set-Content -LiteralPath (Join-Path $output 'Old Name.epub') -Value 'fixture'
    Assert-Equal (Get-StoryOutputFileName -StoryUrl $url -ProposedName 'New Title.epub' -OutputFolder $output -FilenameHistory $history) 'Old Name.epub'
    $history[$key] = 'Old Name.epub'
    Save-StoryFilenameHistory -Path $historyPath -History $history
    Remove-Item -LiteralPath (Join-Path $output 'Old Name.epub')
    $history = Read-StoryFilenameHistory -Path $historyPath
    Assert-Equal (Get-StoryOutputFileName -StoryUrl $url -ProposedName 'New Title.epub' -OutputFolder $output -FilenameHistory $history) 'Old Name.epub'

    Set-Content -LiteralPath (Join-Path $output 'Moved Name.epub') -Value 'fixture'
    Assert-Equal (Get-StoryOutputFileName -StoryUrl $url -ProposedName 'New Title.epub' -OutputFolder $output -FilenameHistory $history) 'Moved Name.epub'
    Remove-Item -LiteralPath (Join-Path $output 'Moved Name.epub')

    Set-Content -LiteralPath (Join-Path $output 'Old Name.epub') -Value 'different story'
    $collision = $false
    try { $null = Get-StoryOutputFileName -StoryUrl $url -ProposedName 'New Title.epub' -OutputFolder $output -FilenameHistory $history }
    catch { $collision = $_.Exception.Message -match 'another story' }
    if (-not $collision) { throw 'Expected collision protection.' }

    $invalid = $false
    Set-Content -LiteralPath $historyPath -Value '{"ao3:91757466":"..\\escape.epub"}'
    try { $null = Read-StoryFilenameHistory -Path $historyPath }
    catch { $invalid = $true }
    if (-not $invalid) { throw 'Expected invalid filename history to be rejected.' }
    Write-Host 'Story filename regression tests passed.'
}
finally {
    Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}
