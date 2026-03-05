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
    [string]  $InstallDir   = "",
    [switch]  $NoModifyPath,
    [switch]  $Uninstall,
    [switch]  $Purge,
    [switch]  $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
  -InstallDir <path>     Install directory (default: `$HOME\.hyperset\cli\bin)
  -NoModifyPath          Do not add install directory to user PATH
  -Uninstall             Remove installed binary
  -Purge                 Remove installed binary and CLI state
  -Help                  Show this help message

Examples:
  irm https://hypersetai.com/cli/install.ps1 | iex
  .\install.ps1 -Version 1.2.3
  .\install.ps1 -Uninstall
  .\install.ps1 -Uninstall -Purge
"@
}

function Get-ManifestContent {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        return $response.Content | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to fetch manifest from ${Url}: $_"
        exit 1
    }
}

function Get-TargetEntry {
    param($Manifest, [string]$Target)
    $targets = $Manifest.targets
    if (-not $targets) {
        Write-Error "Manifest has no 'targets' field."
        exit 1
    }
    $entry = $targets.$Target
    if (-not $entry) {
        Write-Error "No manifest entry for target '${Target}'."
        exit 1
    }
    return $entry
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
        installed_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ" -AsUTC)
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
        Write-Host "Removed installed binaries from $ActualInstDir"
    }
    else {
        Write-Host "No installed binaries found in $ActualInstDir"
    }
    Remove-InstallReceipt
    if ($Purge) {
        if (Test-Path $CliRoot) {
            Remove-Item -Recurse -Force $CliRoot
            Write-Host "Purged $CliRoot"
        }
    }
}

function Update-UserPath {
    if ($NoModifyPath) {
        Write-Host "Skipping PATH modification (-NoModifyPath)."
        return
    }
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $entries = $currentPath -split ";"
    if ($entries -contains $ActualInstDir) {
        return
    }
    $newPath = "${ActualInstDir};${currentPath}"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Host "Added $ActualInstDir to user PATH."
    Write-Host "Restart your terminal for PATH changes to take effect."
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

    Write-Host "Fetching manifest from $manifestUrl ..."
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

        Write-Host "Downloading $archiveName ..."
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing

        Write-Host "Verifying checksum ..."
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
        Write-Host "Installed hyperset.exe to $ActualInstDir"

        $runnerBin = Join-Path $extractDir "hyperset-runner.exe"
        if (Test-Path $runnerBin) {
            Copy-Item -Path $runnerBin -Destination (Join-Path $ActualInstDir "hyperset-runner.exe") -Force
            Write-Host "Installed hyperset-runner.exe to $ActualInstDir"
        }

        Write-InstallReceipt -InstalledVersion $installedVersion
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

Install-Cli
Update-UserPath
Write-Host "Run: ${APP} --version"
