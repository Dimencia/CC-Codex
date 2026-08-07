[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int] $ComputerNumber = 3,

    [switch] $Apply,

    [string] $BaseRoot,

    [string] $ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$computerRoot = 'C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer'
$sourceRoot = Join-Path $PSScriptRoot 'refactored\live'
$computerPath = Join-Path $computerRoot ([string] $ComputerNumber)
$deploymentRoot = Join-Path $PSScriptRoot ('.codex\deployments\computer-{0}' -f $ComputerNumber)

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Repository live tree does not exist: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $computerPath -PathType Container)) {
    throw "Computer directory does not exist: $computerPath"
}

function Normalize-RelativePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return $Path.Replace('\', '/').TrimStart('/')
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $FullName
    )

    return Normalize-RelativePath -Path $FullName.Substring($Root.Length).TrimStart('\', '/')
}

function Test-IgnoredPath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)

    $path = Normalize-RelativePath -Path $RelativePath
    if ($path -eq '.settings') { return $true }
    if ($path -eq 'artifacts' -or $path.StartsWith('artifacts/')) { return $true }
    if ($path -eq 'data/conversations.json') { return $true }
    if ($path -eq 'data/conversations' -or $path.StartsWith('data/conversations/')) { return $true }
    if ($path -match '^data/(codex-state\.json|preferences\.md|usage\.jsonl|tools\.jsonl|host-command-request\.json(?:\.tmp)?|host-command-result\.json(?:\.tmp)?|[^/]+\.tmp)$') { return $true }
    return $false
}

function Get-FileMap {
    param([Parameter(Mandatory = $true)][string] $Root)

    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse)) {
        $relativePath = Get-RelativePath -Root $Root -FullName $file.FullName
        if (-not (Test-IgnoredPath -RelativePath $relativePath)) {
            $map[$relativePath] = $file.FullName
        }
    }
    return $map
}

function Get-Hash {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Cache,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Path
    )

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (-not $Cache.ContainsKey($Path)) {
        $Cache[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $Cache[$Path]
}

function Find-LatestManifest {
    if (-not (Test-Path -LiteralPath $deploymentRoot -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $deploymentRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object {
            $candidate = Join-Path $_.FullName 'manifest.json'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        } | Select-Object -First 1
}

function Get-BaselineRootFromManifest {
    param([Parameter(Mandatory = $true)][string] $ManifestPath)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([int] $manifest.schemaVersion -ne 1) {
        throw "Unsupported deployment manifest schema: $($manifest.schemaVersion)"
    }
    $relativePath = [string] $manifest.baseRelativePath
    $root = Join-Path (Split-Path -Parent $ManifestPath) $relativePath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Deployment baseline is missing: $root"
    }
    return [pscustomobject]@{ Root = $root; Manifest = $manifest }
}

function Invoke-ThreeWayTextMerge {
    param(
        [Parameter(Mandatory = $true)][string] $Ours,
        [Parameter(Mandatory = $true)][string] $Base,
        [Parameter(Mandatory = $true)][string] $Theirs,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory
    )

    $oursTemp = Join-Path $WorkingDirectory 'ours'
    $baseTemp = Join-Path $WorkingDirectory 'base'
    $theirsTemp = Join-Path $WorkingDirectory 'theirs'
    Copy-Item -LiteralPath $Ours -Destination $oursTemp -Force
    Copy-Item -LiteralPath $Base -Destination $baseTemp -Force
    Copy-Item -LiteralPath $Theirs -Destination $theirsTemp -Force

    & git -C $PSScriptRoot merge-file --diff3 --marker-size=7 $oursTemp $baseTemp $theirsTemp 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 1) {
        throw "git merge-file failed for '$Ours' with exit code $exitCode."
    }

    return [pscustomobject]@{
        HasConflict = $exitCode -eq 1
        Bytes = [System.IO.File]::ReadAllBytes($oursTemp)
    }
}

function New-PlanItem {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Action,
        [AllowEmptyString()][string] $Reason = ''
    )

    return [ordered]@{ path = $Path; action = $Action; reason = $Reason }
}

$repoFiles = Get-FileMap -Root $sourceRoot
$computerFiles = Get-FileMap -Root $computerPath
$repoHashes = @{}
$computerHashes = @{}
$baseHashes = @{}
$manifestPath = if ($BaseRoot) { $null } else { Find-LatestManifest }
$baseline = $null
if ($BaseRoot) {
    if (-not (Test-Path -LiteralPath $BaseRoot -PathType Container)) {
        throw "Base root does not exist: $BaseRoot"
    }
    $baseline = [pscustomobject]@{ Root = (Resolve-Path -LiteralPath $BaseRoot).Path; Manifest = $null }
} elseif ($manifestPath) {
    $baseline = Get-BaselineRootFromManifest -ManifestPath $manifestPath
}

$baseFiles = if ($baseline) { Get-FileMap -Root $baseline.Root } else { @{} }
$allPaths = @($repoFiles.Keys + $computerFiles.Keys + $baseFiles.Keys) |
    Sort-Object -Unique
$plan = @()
$workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('cc-codex-merge-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workingDirectory -Force

try {
    foreach ($path in $allPaths) {
        $repoPath = if ($repoFiles.ContainsKey($path)) { $repoFiles[$path] } else { '' }
        $computerFilePath = if ($computerFiles.ContainsKey($path)) { $computerFiles[$path] } else { '' }
        $basePath = if ($baseFiles.ContainsKey($path)) { $baseFiles[$path] } else { '' }
        $repoHash = Get-Hash -Cache $repoHashes -Path $repoPath
        $computerHash = Get-Hash -Cache $computerHashes -Path $computerFilePath
        $baseHash = Get-Hash -Cache $baseHashes -Path $basePath

        if ($repoHash -eq $computerHash) {
            $plan += New-PlanItem -Path $path -Action 'unchanged' -Reason 'Repository and computer match.'
            continue
        }

        if (-not $baseline) {
            if (-not $repoPath -and $computerFilePath) {
                $plan += New-PlanItem -Path $path -Action 'computer-addition' -Reason 'Safe to review, but no deployment baseline exists.'
            } elseif ($repoPath -and -not $computerFilePath) {
                $plan += New-PlanItem -Path $path -Action 'repository-only' -Reason 'Computer does not contain this repository path.'
            } else {
                $plan += New-PlanItem -Path $path -Action 'needs-baseline' -Reason 'Both sides differ and the common deployed content is unknown.'
            }
            continue
        }

        if ($repoHash -eq $baseHash) {
            if ($computerFilePath) {
                $plan += New-PlanItem -Path $path -Action 'take-computer' -Reason 'Repository is unchanged since deployment.'
            } else {
                $plan += New-PlanItem -Path $path -Action 'delete' -Reason 'Computer deleted a file unchanged in the repository.'
            }
            continue
        }

        if ($computerHash -eq $baseHash) {
            if ($repoPath) {
                $plan += New-PlanItem -Path $path -Action 'keep-repository' -Reason 'Computer is unchanged since deployment.'
            } else {
                $plan += New-PlanItem -Path $path -Action 'delete' -Reason 'Repository deleted a file unchanged on the computer.'
            }
            continue
        }

        if (-not $repoPath -or -not $computerFilePath -or -not $basePath) {
            $plan += New-PlanItem -Path $path -Action 'conflict' -Reason 'Both sides changed a file with an add/delete boundary.'
            continue
        }

        $merge = Invoke-ThreeWayTextMerge -Ours $repoPath -Base $basePath -Theirs $computerFilePath -WorkingDirectory $workingDirectory
        if ($merge.HasConflict) {
            $plan += New-PlanItem -Path $path -Action 'conflict' -Reason 'Three-way text merge has overlapping edits.'
        } else {
            $plan += New-PlanItem -Path $path -Action 'merge' -Reason 'Three-way text merge is clean.'
        }
    }

    $counts = [ordered]@{}
    foreach ($item in $plan) {
        if (-not $counts.Contains($item.action)) { $counts[$item.action] = 0 }
        $counts[$item.action]++
    }
    $report = [ordered]@{
        schemaVersion = 1
        computerNumber = $ComputerNumber
        sourceRoot = $sourceRoot
        computerRoot = $computerPath
        baseline = if ($baseline) { $baseline.Root } else { $null }
        manifest = $manifestPath
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        counts = $counts
        files = $plan
    }

    if ($ReportPath) {
        $reportParent = Split-Path -Parent $ReportPath
        if ($reportParent) { $null = New-Item -ItemType Directory -Path $reportParent -Force }
        [System.IO.File]::WriteAllText(
            $ReportPath,
            ($report | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )
    }

    $counts.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object { [pscustomobject]@{ Action = $_.Key; Count = $_.Value } } |
        Format-Table Action,Count -AutoSize |
        Out-String |
        Write-Output
    if (-not $baseline) {
        Write-Output 'No deployment baseline found. This is a read-only classification; content conflicts will not be applied.'
    }

    $conflicts = @($plan | Where-Object { $_.action -in @('conflict', 'needs-baseline') })
    if ($Apply) {
        if (-not $baseline) {
            throw 'Refusing to apply without a deployment baseline. Use -BaseRoot with an immutable pre-edit snapshot.'
        }
        if ($conflicts.Count -gt 0) {
            throw "Refusing to apply because $($conflicts.Count) file conflict(s) require review."
        }

        $backupRoot = Join-Path $PSScriptRoot ('.codex\merge-backups\computer-{0}\{1}' -f $ComputerNumber, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
        $appliedCount = 0
        foreach ($item in $plan | Where-Object { $_.action -in @('take-computer', 'merge', 'delete') }) {
            $destination = Join-Path $sourceRoot ($item.path.Replace('/', '\'))
            $computerFilePath = Join-Path $computerPath ($item.path.Replace('/', '\'))
            if (-not $PSCmdlet.ShouldProcess($destination, "Apply $($item.action) from computer $ComputerNumber")) {
                continue
            }

            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $backupPath = Join-Path $backupRoot ($item.path.Replace('/', '\'))
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force
                Copy-Item -LiteralPath $destination -Destination $backupPath -Force
            }

            if ($item.action -eq 'take-computer' -or $item.action -eq 'merge') {
                $parent = Split-Path -Parent $destination
                $null = New-Item -ItemType Directory -Path $parent -Force
                if ($item.action -eq 'take-computer') {
                    Copy-Item -LiteralPath $computerFilePath -Destination $destination -Force
                } else {
                    $merge = Invoke-ThreeWayTextMerge -Ours $destination -Base $baseFiles[$item.path] -Theirs $computerFilePath -WorkingDirectory $workingDirectory
                    [System.IO.File]::WriteAllBytes($destination, $merge.Bytes)
                }
            } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
                Remove-Item -LiteralPath $destination -Force
            }
            $appliedCount++
        }
        if ($appliedCount -gt 0) {
            Write-Output "Applied $appliedCount clean change(s). Repository backup: $backupRoot"
        } else {
            Write-Output 'No changes were applied.'
        }
    }
} finally {
    if (Test-Path -LiteralPath $workingDirectory) {
        Remove-Item -LiteralPath $workingDirectory -Recurse -Force
    }
}
