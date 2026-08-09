Set-StrictMode -Version Latest

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-ValidRunId {
    param([Parameter(Mandatory)][string]$RunId)

    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "-RunId must be 1-64 characters and contain only letters, digits, '.', '_' or '-'."
    }
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath -ne $fullRoot -and -not $fullPath.StartsWith("$fullRoot\", $comparison) -and -not $fullPath.StartsWith("$fullRoot/", $comparison)) {
        throw "Path '$fullPath' is outside the allowed output root '$fullRoot'."
    }
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    return (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
}

function Get-SourceIdentity {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RuntimeDirectory
    )

    $sourceSha = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceSha -notmatch '^[0-9a-f]{40}$') {
        throw 'Could not determine the exact checkout SHA for runtime evidence.'
    }

    foreach ($diffArguments in @(
        @('diff', '--quiet', 'HEAD', '--', 'computer', 'tests/runtime', '.dockerignore'),
        @('diff', '--cached', '--quiet', '--', 'computer', 'tests/runtime', '.dockerignore')
    )) {
        & git -C $RepositoryRoot @diffArguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The runtime source or fixture inputs are modified; exact-head evidence requires a clean relevant tree.'
        }
    }

    $status = (@(& git -C $RepositoryRoot status --porcelain --untracked-files=all -- computer tests/runtime .dockerignore) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect runtime source cleanliness.'
    }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'The runtime source or fixture inputs contain untracked files; exact-head evidence requires a clean relevant tree.'
    }

    $fingerprintLines = @()
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'computer') -File -Recurse) {
        $relativePath = [System.IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/')
        $fingerprintLines += "$relativePath|$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    foreach ($file in Get-ChildItem -LiteralPath $RuntimeDirectory -File -Recurse) {
        $relativePath = [System.IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/')
        if ($relativePath -like 'tests/runtime/output/*' -or $relativePath -like 'tests/runtime/output-diagnostic/*') { continue }
        $fingerprintLines += "$relativePath|$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $dockerIgnore = Join-Path $RepositoryRoot '.dockerignore'
    if (Test-Path -LiteralPath $dockerIgnore) {
        $fingerprintLines += ".dockerignore|$((Get-FileHash -LiteralPath $dockerIgnore -Algorithm SHA256).Hash.ToLowerInvariant())"
    }

    $inputFingerprint = ($fingerprintLines | Sort-Object) -join "`n"
    [pscustomobject]@{
        source_sha = $sourceSha
        input_sha = Get-Sha256Text -Value $inputFingerprint
    }
}

function Get-RunIdentity {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][psobject]$Source
    )

    Assert-ValidRunId -RunId $RunId
    $canonicalRoot = Get-CanonicalPath -Path $RepositoryRoot
    $scopeKey = (Get-Sha256Text -Value "$canonicalRoot`n$RunId").Substring(0, 32)
    $imageKey = (Get-Sha256Text -Value "$($Source.source_sha)`n$($Source.input_sha)").Substring(0, 32)
    $runOutput = Join-Path ([System.IO.Path]::GetFullPath($OutputRoot)) $scopeKey
    Assert-PathWithinRoot -Path $runOutput -Root $OutputRoot

    [pscustomobject]@{
        run_id = $RunId
        canonical_worktree = $canonicalRoot
        scope_key = $scopeKey
        image_key = $imageKey
        image_name = "cc-codex-rt-i-$imageKey`:local"
        container_name = "cc-codex-rt-c-$scopeKey"
        container_id = $null
        output_root = [System.IO.Path]::GetFullPath($OutputRoot)
        output_path = $runOutput
        source_sha = $Source.source_sha
        input_sha = $Source.input_sha
    }
}

function Write-RunManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][psobject]$Identity,
        [Parameter(Mandatory)][string]$Status,
        [int]$ExitCode,
        [string]$Failure,
        [psobject]$Evidence
    )

    $manifest = [ordered]@{
        schema = 1
        agent = 'Quanta (benchmark tester)'
        status = $Status
        run_id = $Identity.run_id
        source_sha = $Identity.source_sha
        input_sha = $Identity.input_sha
        canonical_worktree = $Identity.canonical_worktree
        scope_key = $Identity.scope_key
        image_key = $Identity.image_key
        image_name = $Identity.image_name
        container_name = $Identity.container_name
        container_id = $Identity.container_id
        output_path = $Identity.output_path
        exit_code = $ExitCode
    }
    if (-not [string]::IsNullOrWhiteSpace($Failure)) { $manifest.failure = $Failure }
    if ($null -ne $Evidence) { $manifest.evidence = $Evidence }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-OutputEvidence {
    param([Parameter(Mandatory)][string]$OutputPath)

    $files = @()
    foreach ($file in Get-ChildItem -LiteralPath $OutputPath -File -Recurse | Where-Object { $_.Name -notin @('run-manifest.json', 'runtime-evidence.json') }) {
        $relativePath = [System.IO.Path]::GetRelativePath($OutputPath, $file.FullName).Replace('\', '/')
        $files += [pscustomobject]@{
            path = $relativePath
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            bytes = $file.Length
        }
    }
    $ordered = @($files | Sort-Object path)
    $fingerprint = ($ordered | ForEach-Object { "$($_.path)|$($_.sha256)|$($_.bytes)" }) -join "`n"
    [pscustomobject]@{
        output_sha256 = Get-Sha256Text -Value $fingerprint
        files = $ordered
    }
}

function Remove-OwnedDockerContainer {
    param(
        [Parameter(Mandatory)][string]$DockerCommand,
        [Parameter(Mandatory)][string]$ContainerId,
        [Parameter(Mandatory)][psobject]$Identity
    )

    $labelsJson = & $DockerCommand inspect --format '{{json .Config.Labels}}' $ContainerId 2>$null
    if ($LASTEXITCODE -ne 0) {
        # An exited --rm container is already cleaned. No name-based lookup is attempted.
        return 'absent'
    }
    try { $labels = ($labelsJson -join "`n") | ConvertFrom-Json } catch { throw 'Docker ownership metadata was not valid JSON; refusing cleanup.' }
    if ($null -eq $labels -or $labels.'cc-codex.owner' -ne 'runtime-fixture' -or $labels.'cc-codex.scope' -ne $Identity.scope_key -or $labels.'cc-codex.run' -ne $Identity.run_id -or $labels.'cc-codex.source' -ne $Identity.source_sha) {
        throw "Docker container '$ContainerId' did not match this run's ownership labels; refusing cleanup."
    }
    & $DockerCommand rm --force $ContainerId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Owned Docker container cleanup failed for '$ContainerId'." }
    return 'removed'
}
