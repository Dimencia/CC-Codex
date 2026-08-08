[CmdletBinding()]
param(
    [string] $HeadPrefix = 'codex/',
    [ValidateRange(1, 500)]
    [int] $Limit = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is not installed or is not on PATH. Use the connected GitHub app or install gh.'
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated. Use the connected GitHub app or run: gh auth login'
}

$ghArguments = @(
    'pr', 'list',
    '--state', 'open',
    '--limit', [string] $Limit,
    '--json', 'number,title,url,headRefName,headRefOid,baseRefName,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,updatedAt'
)

$raw = & gh @ghArguments
if ($LASTEXITCODE -ne 0) {
    throw 'gh pr list failed.'
}

$pullRequests = @($raw | ConvertFrom-Json) | Where-Object {
    $null -ne $_ -and $_.headRefName -like "$HeadPrefix*"
}

function Get-CheckState {
    param([object[]] $Rollup)

    $checks = @($Rollup)
    if ($checks.Count -eq 0) {
        return 'none'
    }

    $values = @(foreach ($check in $checks) {
        foreach ($propertyName in @('conclusion', 'state', 'status')) {
            $property = $check.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                ([string] $property.Value).ToUpperInvariant()
            }
        }
    })

    $failureStates = @('FAILURE', 'FAILED', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'STALE')
    if (@($values | Where-Object { $_ -in $failureStates }).Count -gt 0) {
        return 'failing'
    }

    $pendingStates = @('EXPECTED', 'PENDING', 'QUEUED', 'IN_PROGRESS', 'REQUESTED', 'WAITING')
    if (@($values | Where-Object { $_ -in $pendingStates }).Count -gt 0) {
        return 'pending'
    }

    $successStates = @('SUCCESS', 'SUCCESSFUL', 'NEUTRAL', 'SKIPPED')
    if ($values.Count -gt 0 -and @($values | Where-Object { $_ -notin $successStates }).Count -eq 0) {
        return 'passing'
    }

    return 'unknown'
}

$result = foreach ($pr in $pullRequests) {
    [pscustomobject]@{
        number     = $pr.number
        title      = $pr.title
        url        = $pr.url
        head       = $pr.headRefName
        headSha    = $pr.headRefOid
        base       = $pr.baseRefName
        draft      = $pr.isDraft
        mergeState = $pr.mergeStateStatus
        review     = $pr.reviewDecision
        checks     = Get-CheckState -Rollup @($pr.statusCheckRollup)
        updatedAt  = $pr.updatedAt
    }
}

ConvertTo-Json -InputObject @($result) -Depth 5 -Compress
