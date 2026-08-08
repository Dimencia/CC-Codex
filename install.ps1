<##
.SYNOPSIS
    Installs the shared CC Codex source links into a ComputerCraft computer.

.DESCRIPTION
    The target is the exact ComputerCraft computer directory supplied through
    -TargetPath.
    startup.lua and codex.lua become file symlinks to the repository source;
    lib becomes a directory junction. Runtime data, artifacts, and .settings
    are left alone.

    Existing matching links are left in place. Conflicting entries are refused
    unless -Force is supplied; -Force moves them to a timestamped backup under
    the target's parent directory before creating the new links.

.EXAMPLE
    .\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3'

.EXAMPLE
    .\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3' -WhatIf
##>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [Alias('ComputerPath')]
    [string] $TargetPath,

    [string] $RepositoryRoot,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Directory {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description does not exist as a directory: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-Directory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create directory')) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ExistingEntry {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    } catch [System.IO.FileNotFoundException] {
        return $null
    } catch [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

function Get-NormalizedTarget {
    param([Parameter(Mandatory = $true)][object] $Item)

    $targetProperty = $Item.PSObject.Properties['Target']
    if ($null -eq $targetProperty -or $null -eq $targetProperty.Value) { return $null }
    $rawTarget = $targetProperty.Value
    if ($rawTarget -is [array]) { $rawTarget = $rawTarget[0] }
    if ([string]::IsNullOrWhiteSpace([string] $rawTarget)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath([string] $rawTarget)
    } catch {
        return $null
    }
}

function Test-ExpectedLink {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('SymbolicLink', 'Junction')][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Target
    )

    $item = Get-ExistingEntry -Path $Path
    if ($null -eq $item) { return $false }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    if ([string] $item.LinkType -ne $Kind) { return $false }
    $actualTarget = Get-NormalizedTarget -Item $item
    if ($null -eq $actualTarget) { return $false }
    return [string]::Equals(
        $actualTarget,
        [System.IO.Path]::GetFullPath($Target),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function New-FileSymbolicLink {
    param(
        [Parameter(Mandatory = $true)][string] $LinkPath,
        [Parameter(Mandatory = $true)][string] $TargetPath
    )

    $command = 'mklink "{0}" "{1}"' -f $LinkPath, $TargetPath
    & cmd.exe /d /c $command | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create symbolic link: $LinkPath"
    }
}

$repositoryInput = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $PSScriptRoot } else { $RepositoryRoot }
$repository = Resolve-Directory -Path $repositoryInput -Description 'Repository root'
$sourceRoot = Resolve-Directory -Path (Join-Path $repository 'computer') -Description 'Repository computer source'

$sourceStartup = Join-Path $sourceRoot 'startup.lua'
$sourceCodex = Join-Path $sourceRoot 'codex.lua'
$sourceLib = Join-Path $sourceRoot 'lib'
if (-not (Test-Path -LiteralPath $sourceStartup -PathType Leaf)) { throw "Missing source file: $sourceStartup" }
if (-not (Test-Path -LiteralPath $sourceCodex -PathType Leaf)) { throw "Missing source file: $sourceCodex" }
if (-not (Test-Path -LiteralPath $sourceLib -PathType Container)) { throw "Missing source directory: $sourceLib" }

$computerRoot = [System.IO.Path]::GetFullPath($TargetPath)
$computerParent = Split-Path -Path $computerRoot -Parent
if (-not (Test-Path -LiteralPath $computerParent -PathType Container)) {
    throw "Target parent directory does not exist: $computerParent"
}
Ensure-Directory -Path $computerRoot

$entries = @(
    [pscustomobject]@{ Name = 'startup.lua'; Kind = 'SymbolicLink'; Target = $sourceStartup },
    [pscustomobject]@{ Name = 'codex.lua'; Kind = 'SymbolicLink'; Target = $sourceCodex },
    [pscustomobject]@{ Name = 'lib'; Kind = 'Junction'; Target = $sourceLib }
)

$conflicts = @()
foreach ($entry in $entries) {
    $path = Join-Path $computerRoot $entry.Name
    if (Test-ExpectedLink -Path $path -Kind $entry.Kind -Target $entry.Target) {
        Write-Host "Already linked: $path"
        continue
    }
    if ($null -ne (Get-ExistingEntry -Path $path)) {
        $conflicts += [pscustomobject]@{ Entry = $entry; Path = $path }
    }
}

if ($conflicts.Count -gt 0 -and -not $Force) {
    $paths = ($conflicts | ForEach-Object { $_.Path }) -join [Environment]::NewLine
    throw "Conflicting existing entries were found. Use -Force to back them up before replacing them:`n$paths"
}

if ($conflicts.Count -gt 0) {
    $targetName = Split-Path -Path $computerRoot -Leaf
    $backupRoot = Join-Path $computerParent ('.cc-codex-install-backups\{0}\{1}' -f $targetName, (Get-Date -Format 'yyyyMMddTHHmmssfff'))
    Ensure-Directory -Path $backupRoot
    foreach ($conflict in $conflicts) {
        $backupPath = Join-Path $backupRoot $conflict.Entry.Name
        if ($PSCmdlet.ShouldProcess($conflict.Path, "Move existing entry to $backupPath")) {
            Move-Item -LiteralPath $conflict.Path -Destination $backupPath
        }
    }
}

foreach ($entry in $entries) {
    $path = Join-Path $computerRoot $entry.Name
    if (Test-ExpectedLink -Path $path -Kind $entry.Kind -Target $entry.Target) { continue }
    if ($entry.Kind -eq 'SymbolicLink') {
        if ($PSCmdlet.ShouldProcess($path, "Create file symlink to $($entry.Target)")) {
            New-FileSymbolicLink -LinkPath $path -TargetPath $entry.Target
        }
    } else {
        if ($PSCmdlet.ShouldProcess($path, "Create directory junction to $($entry.Target)")) {
            New-Item -ItemType Junction -Path $path -Target $entry.Target | Out-Null
        }
    }
}

Write-Host "CC Codex source installation prepared at $computerRoot."
Write-Host 'Runtime data, artifacts, and .settings were not changed.'
