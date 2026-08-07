[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int] $ComputerNumber = 3,

    [switch] $DryRun,

    [string] $GitBranch
)

$ErrorActionPreference = 'Stop'

$sourceRoot = Join-Path $PSScriptRoot 'refactored\live'
$computerRoot = 'C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer'
$targetRoot = Join-Path $computerRoot ([string] $ComputerNumber)

if ($GitBranch) {
    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        throw "Computer directory does not exist: $targetRoot"
    }

    & git -C $PSScriptRoot show-ref --verify --quiet ("refs/heads/{0}" -f $GitBranch)
    if ($LASTEXITCODE -ne 0) {
        throw "Local Git branch does not exist: $GitBranch. Commit the repository changes before Git deployment."
    }

    $targetIsGitCheckout = $true
    try {
        $null = & git -c ("safe.directory={0}" -f $targetRoot) -C $targetRoot rev-parse --is-inside-work-tree 2>$null
        $targetIsGitCheckout = $LASTEXITCODE -eq 0
    } catch {
        $targetIsGitCheckout = $false
    }
    if (-not $targetIsGitCheckout) {
        throw "Computer $ComputerNumber is not a Git checkout. Initialize it with git-computer.ps1 first."
    }

    $dirtyFiles = @(& git -c ("safe.directory={0}" -f $targetRoot) -C $targetRoot status --porcelain)
    if ($dirtyFiles.Count -gt 0) {
        throw "Computer $ComputerNumber has uncommitted changes. Commit or preserve them before Git deployment."
    }

    $currentBranch = (& git -c ("safe.directory={0}" -f $targetRoot) -C $targetRoot branch --show-current).Trim()
    if ($DryRun) {
        Write-Host "Would fast-forward computer $ComputerNumber branch '$currentBranch' from local branch '$GitBranch'."
        return
    }

    & git -c ("safe.directory={0}" -f $targetRoot) -C $targetRoot fetch --no-tags --prune $PSScriptRoot $GitBranch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch local branch '$GitBranch' into computer $ComputerNumber."
    }
    & git -c ("safe.directory={0}" -f $targetRoot) -C $targetRoot merge --ff-only FETCH_HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Git deployment stopped: computer $ComputerNumber cannot fast-forward to '$GitBranch'."
    }
    Write-Host "Git deployment complete: computer $ComputerNumber now follows '$GitBranch'."
    return
}

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Staged CC Codex directory does not exist: $sourceRoot"
}

$sourceRoot = (Resolve-Path -LiteralPath $sourceRoot).Path.TrimEnd('\', '/')
$runtimeGuideRelativePath = 'data/lua_structure.md'
$runtimeGuideSourcePath = Join-Path $sourceRoot $runtimeGuideRelativePath
if (-not (Test-Path -LiteralPath $runtimeGuideSourcePath -PathType Leaf)) {
    throw "Required CC runtime documentation is missing: $runtimeGuideRelativePath"
}

$directories = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse)
$secretSettingsPath = Join-Path $sourceRoot '.settings'
$files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Where-Object {
    -not [string]::Equals(
        $_.FullName,
        $secretSettingsPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )
})

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

function Get-RelativeStagedPath {
    param([Parameter(Mandatory = $true)][string] $FullName)

    return $FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
}

function Ensure-TargetDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return
    }
    if ($DryRun) {
        Write-Host "Would create directory: $Path"
        return
    }
    $null = New-Item -ItemType Directory -Path $Path -Force
}

function Get-DeploymentRelativePath {
    param([Parameter(Mandatory = $true)][string] $FullName)

    return $FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
}

if (-not $DryRun) {
    $deploymentId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $deploymentRoot = Join-Path $PSScriptRoot ('.codex\deployments\computer-{0}\{1}' -f $ComputerNumber, $deploymentId)
    $baselineRoot = Join-Path $deploymentRoot 'base'
    $null = New-Item -ItemType Directory -Path $baselineRoot -Force

    foreach ($file in $files) {
        $relativePath = Get-DeploymentRelativePath -FullName $file.FullName
        $baselinePath = Join-Path $baselineRoot $relativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $baselinePath) -Force
        Copy-Item -LiteralPath $file.FullName -Destination $baselinePath -Force
    }

    $manifestFiles = @($files | ForEach-Object {
        $relativePath = Get-DeploymentRelativePath -FullName $_.FullName
        [ordered]@{
            path = $relativePath.Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    })
    $manifest = [ordered]@{
        schemaVersion = 1
        computerNumber = $ComputerNumber
        createdUtc = [DateTime]::UtcNow.ToString('o')
        sourceRelativePath = 'refactored/live'
        baseRelativePath = 'base'
        files = $manifestFiles
    }
    $manifestPath = Join-Path $deploymentRoot 'manifest.json'
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 6),
        $utf8WithoutBom
    )
}

Ensure-TargetDirectory -Path $targetRoot
foreach ($directory in $directories) {
    $relativePath = Get-RelativeStagedPath -FullName $directory.FullName
    Ensure-TargetDirectory -Path (Join-Path $targetRoot $relativePath)
}

foreach ($file in $files) {
    $relativePath = Get-RelativeStagedPath -FullName $file.FullName
    $destination = Join-Path $targetRoot $relativePath
    if ($DryRun) {
        Write-Host "Would copy: $relativePath"
        continue
    }

    Ensure-TargetDirectory -Path (Split-Path -Parent $destination)
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force

    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "Hash verification failed after copying: $relativePath"
    }
}

if ($DryRun) {
    Write-Host "Dry run complete: $($files.Count) staged files would be copied to computer $ComputerNumber, including $runtimeGuideRelativePath."
} else {
    $runtimeGuideDestinationPath = Join-Path $targetRoot $runtimeGuideRelativePath
    if (-not (Test-Path -LiteralPath $runtimeGuideDestinationPath -PathType Leaf)) {
        throw "Runtime documentation was not deployed: $runtimeGuideRelativePath"
    }
    $runtimeGuideSourceHash = (Get-FileHash -LiteralPath $runtimeGuideSourcePath -Algorithm SHA256).Hash
    $runtimeGuideDestinationHash = (Get-FileHash -LiteralPath $runtimeGuideDestinationPath -Algorithm SHA256).Hash
    if ($runtimeGuideSourceHash -ne $runtimeGuideDestinationHash) {
        throw "Hash verification failed after copying: $runtimeGuideRelativePath"
    }
    Write-Host "Deployment complete: copied and verified $($files.Count) files on computer $ComputerNumber, including $runtimeGuideRelativePath."
}
