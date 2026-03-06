<#
.SYNOPSIS
    Hyperset CLI installer for Windows.

.DESCRIPTION
    Downloads and installs the hyperset CLI binary for Windows x64.
    Reads the manifest from get-cli, verifies SHA256, and installs to the target directory.
    Also installs the bundled hyperset-runner binary if present in the archive.

.PARAMETER Version
    Install a specific version (e.g. 1.2.3 or v1.2.3). Defaults to latest.

.PARAMETER InstallDir
    Directory to install the binary into. Defaults to $HOME\.hyperset\cli\bin.

.PARAMETER NoModifyPath
    Skip adding InstallDir to the user PATH.

.PARAMETER Uninstall
    Remove the installed binary.

.PARAMETER Purge
    Remove the installed binary and all CLI state ($HOME\.hyperset\cli).

.PARAMETER Binary
    Install from a local binary path instead of downloading from GitHub.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    irm https://hypersetai.com/cli/install.ps1 | iex

.EXAMPLE
    irm https://hypersetai.com/cli/install.ps1 -OutFile install.ps1
    .\install.ps1 -Version 1.2.3

.EXAMPLE
    .\install.ps1 -Uninstall

.EXAMPLE
    .\install.ps1 -Uninstall -Purge
#>
[CmdletBinding()]
param(
    [string]  $Version      = "",
    [string]  $Binary       = "",
    [string]  $InstallDir   = "",
    [switch]  $NoModifyPath,
    [switch]  $Uninstall,
    [switch]  $Purge,
    [switch]  $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ok    { param([string]$msg) Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Value { param([string]$label, [string]$val)
    Write-Host "  $label" -NoNewline; Write-Host $val -ForegroundColor Cyan }

$APP            = "hyperset"
$DIST_REPO      = if ($env:HYPERSET_DIST_REPO) { $env:HYPERSET_DIST_REPO } else { "hypersetai/get-cli" }
$DIST_BRANCH    = if ($env:HYPERSET_DIST_BRANCH) { $env:HYPERSET_DIST_BRANCH } else { "main" }
$HypersetHome   = if ($env:HYPERSET_HOME) { $env:HYPERSET_HOME } else { Join-Path $HOME ".hyperset" }
$DefaultInstDir = Join-Path $HypersetHome "cli\bin"
$ActualInstDir  = if ($InstallDir) { $InstallDir } else { $DefaultInstDir }
$ReceiptPath    = Join-Path $HypersetHome "cli\install.json"
$LegacyReceipt  = Join-Path $HypersetHome "install.json"
$CliRoot        = Join-Path $HypersetHome "cli"

function Show-Help {
    Write-Host @"
Hyperset CLI Installer

Usage: install.ps1 [options]

Parameters:
  -Version <version>     Install specific version (e.g. 1.2.3 or v1.2.3)
  -Binary <path>         Install from local binary path instead of downloading
  -InstallDir <path>     Install directory (default: `$HOME\.hyperset\cli\bin)
  -NoModifyPath          Do not add install directory to user PATH
  -Uninstall             Remove installed binary
  -Purge                 Remove installed binary and CLI state
  -Help                  Show this help message

Examples:
  irm https://hypersetai.com/cli/install.ps1 | iex
  .\install.ps1 -Version 1.2.3
  .\install.ps1 -Binary .\hyperset.exe
  .\install.ps1 -Uninstall
  .\install.ps1 -Uninstall -Purge
"@
}

function Get-ManifestContent {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to fetch manifest from ${Url}: $_"
        exit 1
    }
}

function Get-TargetEntry {
    param($Manifest, [string]$Target)
    $targetsProp = $Manifest.PSObject.Properties['targets']
    if (-not $targetsProp) {
        Write-Error "Manifest has no 'targets' field."
        exit 1
    }
    $targets = $targetsProp.Value
    $entryProp = $targets.PSObject.Properties[$Target]
    if (-not $entryProp) {
        Write-Error "No manifest entry for target '${Target}'."
        exit 1
    }
    return $entryProp.Value
}

function Test-Checksum {
    param([string]$FilePath, [string]$Expected)
    $actual   = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    $expected = $Expected.ToLower()
    if ($actual -ne $expected) {
        Write-Error "Checksum mismatch for $(Split-Path $FilePath -Leaf).`n  Expected: $expected`n  Actual:   $actual"
        exit 1
    }
}

function Write-InstallReceipt {
    param([string]$InstalledVersion)
    $dir = Split-Path $ReceiptPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $receipt = [ordered]@{
        channel      = "powershell"
        version      = $InstalledVersion
        install_dir  = $ActualInstDir
        installed_at = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $receipt | ConvertTo-Json | Set-Content -Path $ReceiptPath -Encoding UTF8
}

function Remove-InstallReceipt {
    if (Test-Path $ReceiptPath)   { Remove-Item -Path $ReceiptPath   -Force }
    if (Test-Path $LegacyReceipt) { Remove-Item -Path $LegacyReceipt -Force }
}

function Invoke-Uninstall {
    $removed = $false
    foreach ($bin in @("${APP}.exe", "hyperset-runner.exe")) {
        $binPath = Join-Path $ActualInstDir $bin
        if (Test-Path $binPath) {
            Remove-Item -Path $binPath -Force
            $removed = $true
        }
    }
    if ($removed) {
        Write-Ok "Removed installed binaries from $ActualInstDir"
    }
    else {
        Write-Warn "No installed binaries found in $ActualInstDir"
    }
    Remove-InstallReceipt
    if ($Purge) {
        if (Test-Path $CliRoot) {
            Remove-Item -Recurse -Force $CliRoot
            Write-Ok "Purged $CliRoot"
        }
    }
}

function Update-UserPath {
    if ($NoModifyPath) {
        Write-Warn "Skipping PATH modification (-NoModifyPath)."
        return
    }
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $entries = $currentPath -split ";"
    if ($entries -contains $ActualInstDir) {
        return
    }
    $newPath = "${ActualInstDir};${currentPath}"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    $sessionEntries = $env:PATH -split ";"
    if (-not ($sessionEntries -contains $ActualInstDir)) {
        Write-Host ""
        Write-Warn "Setup notes:"
        Write-Host "  Native installation exists but " -NoNewline
        Write-Host $ActualInstDir -ForegroundColor Cyan -NoNewline
        Write-Host " is not in your PATH."
        Write-Host "  Add it by opening: System Properties -> Environment Variables -> Edit User PATH -> New"
        Write-Host "  Add the path above. Then restart your terminal."
        Write-Host ""
    }
}

function Install-FromLocalBinary {
    if (-not (Test-Path $Binary)) {
        Write-Error "Local binary not found: $Binary"
        exit 1
    }
    if (-not (Test-Path $ActualInstDir)) {
        New-Item -ItemType Directory -Path $ActualInstDir -Force | Out-Null
    }
    $destName = if ($Binary -match '\.exe$') { "hyperset.exe" } else { "hyperset" }
    Copy-Item -Path $Binary -Destination (Join-Path $ActualInstDir $destName) -Force
    Write-InstallReceipt -InstalledVersion "local"
    Write-Host ""
    Write-Ok "Hyperset CLI installed from local binary!"
    Write-Host ""
    Write-Value "Location: " (Join-Path $ActualInstDir $destName)
    Write-Host ""
}

function Install-Cli {
    $target = "win32-x64"

    $manifestUrl = if ($Version) {
        $vtag = if ($Version.StartsWith("v")) { $Version } else { "v${Version}" }
        "https://github.com/${DIST_REPO}/releases/download/${vtag}/manifest.json"
    }
    else {
        "https://raw.githubusercontent.com/${DIST_REPO}/${DIST_BRANCH}/manifest.json"
    }

    Write-Host "Setting up Hyperset CLI..."
    Write-Host "Fetching manifest..." -ForegroundColor DarkGray
    $manifest = Get-ManifestContent -Url $manifestUrl
    $entry    = Get-TargetEntry -Manifest $manifest -Target $target

    $archiveUrl       = $entry.url
    $expectedSha      = $entry.sha256
    $installedVersion = if ($manifest.version) { $manifest.version } else { $Version.TrimStart("v") }

    if (-not $archiveUrl -or -not $expectedSha) {
        Write-Error "Manifest entry for '${target}' is missing url or sha256."
        exit 1
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $archiveName = Split-Path $archiveUrl -Leaf
        $archivePath = Join-Path $tmpDir $archiveName

        Write-Host "Downloading $archiveName ..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing

        Write-Host "Verifying checksum ..." -ForegroundColor DarkGray
        Test-Checksum -FilePath $archivePath -Expected $expectedSha

        $extractDir = Join-Path $tmpDir "extract"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

        $cliBin = Join-Path $extractDir "hyperset.exe"
        if (-not (Test-Path $cliBin)) {
            Write-Error "hyperset.exe not found in archive."
            exit 1
        }

        if (-not (Test-Path $ActualInstDir)) {
            New-Item -ItemType Directory -Path $ActualInstDir -Force | Out-Null
        }

        Copy-Item -Path $cliBin -Destination (Join-Path $ActualInstDir "hyperset.exe") -Force

        $runnerBin = Join-Path $extractDir "hyperset-runner.exe"
        if (Test-Path $runnerBin) {
            Copy-Item -Path $runnerBin -Destination (Join-Path $ActualInstDir "hyperset-runner.exe") -Force
        }

        Write-InstallReceipt -InstalledVersion $installedVersion

        Write-Host ""
        Write-Ok "Hyperset CLI successfully installed!"
        Write-Host ""
        Write-Value "Version:  " $installedVersion
        Write-Value "Location: " (Join-Path $ActualInstDir "hyperset.exe")
        Write-Host ""
        Write-Host "  Next: Run " -NoNewline
        Write-Host "hyperset --help" -ForegroundColor White -NoNewline
        Write-Host " to get started"
        Write-Host ""
    }
    finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

if ($Help) {
    Show-Help
    exit 0
}

if ($Uninstall -or $Purge) {
    Invoke-Uninstall
    exit 0
}

if ($Binary) {
    Install-FromLocalBinary
}
else {
    Install-Cli
}
Update-UserPath
Write-Ok "Installation complete!"
