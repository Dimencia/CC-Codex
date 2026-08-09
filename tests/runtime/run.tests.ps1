[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'run-support.ps1')

function Assert-Throws {
    param([scriptblock]$Action)
    try { & $Action } catch { return }
    throw 'Expected the action to reject its input.'
}

$source = [pscustomobject]@{
    source_sha = '052c48132ede2ff3fe90b05aeec10d274431d81d'
    input_sha = Get-Sha256Text -Value 'fixture-inputs'
}
$savedRunnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
$savedTemp = [Environment]::GetEnvironmentVariable('TEMP')
try {
    [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $null)
    [Environment]::SetEnvironmentVariable('TEMP', $null)
    $fallbackTempRoot = Get-RuntimeTempRoot
    if ([string]::IsNullOrWhiteSpace($fallbackTempRoot)) { throw 'Portable temporary-root fallback was empty.' }
}
finally {
    [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $savedRunnerTemp)
    [Environment]::SetEnvironmentVariable('TEMP', $savedTemp)
}
$outputRoot = Join-Path (Get-RuntimeTempRoot) 'cc-codex-runtime-isolation-tests'
$identityA = Get-RunIdentity -RepositoryRoot $PSScriptRoot -RuntimeDirectory $PSScriptRoot -RunId 'ci-123' -OutputRoot $outputRoot -Source $source
$identityB = Get-RunIdentity -RepositoryRoot $PSScriptRoot -RuntimeDirectory $PSScriptRoot -RunId 'ci-123' -OutputRoot $outputRoot -Source $source
if ($identityA.scope_key -ne $identityB.scope_key -or $identityA.image_key -ne $identityB.image_key) { throw 'Identity derivation was not deterministic.' }
if ($identityA.container_name -notmatch '^cc-codex-rt-c-[0-9a-f]{32}$' -or $identityA.image_name -notmatch '^cc-codex-rt-i-[0-9a-f]{32}:local$') { throw 'Resource names were not bounded hexadecimal names.' }
if ($identityA.container_name -match 'ci-123' -or $identityA.image_name -match 'ci-123') { throw 'Raw RunId leaked into a resource name.' }

Assert-Throws { Assert-ValidRunId -RunId 'bad/run' }
Assert-Throws { Assert-ValidRunId -RunId ('x' * 65) }
$foreignPath = Join-Path (Split-Path -Parent $outputRoot) 'foreign'
Assert-Throws { Assert-PathWithinRoot -Path $foreignPath -Root $outputRoot }

$tempRoot = Get-RuntimeTempRoot
$fakeDocker = Join-Path $tempRoot "cc-codex-fake-docker-$([Guid]::NewGuid().ToString('N')).ps1"
$rmLog = Join-Path $tempRoot "cc-codex-fake-docker-rm-$([Guid]::NewGuid().ToString('N')).txt"
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
if ($Arguments -contains 'inspect') {
    if ($env:CC_CODEX_FAKE_DOCKER_MODE -eq 'foreign') {
        Write-Output '{"cc-codex.owner":"runtime-fixture","cc-codex.scope":"foreign","cc-codex.run":"foreign","cc-codex.source":"foreign"}'
    } else {
        Write-Output ('{"cc-codex.owner":"runtime-fixture","cc-codex.scope":"' + $env:CC_CODEX_FAKE_SCOPE + '","cc-codex.run":"ci-123","cc-codex.source":"' + $env:CC_CODEX_FAKE_SOURCE + '"}')
    }
    exit 0
}
if ($Arguments -contains 'rm') { Add-Content -LiteralPath $env:CC_CODEX_FAKE_RM_LOG -Value 'removed'; exit 0 }
exit 0
'@ | Set-Content -LiteralPath $fakeDocker -Encoding utf8

$env:CC_CODEX_FAKE_SCOPE = $identityA.scope_key
$env:CC_CODEX_FAKE_SOURCE = $identityA.source_sha
$env:CC_CODEX_FAKE_RM_LOG = $rmLog
$env:CC_CODEX_FAKE_DOCKER_MODE = 'owned'
Remove-OwnedDockerContainer -DockerCommand $fakeDocker -ContainerId 'abc123' -Identity $identityA | Out-Null
if ((Get-Content -Raw -LiteralPath $rmLog).Trim() -ne 'removed') { throw 'Owned container was not cleaned after the interruption path.' }

Remove-Item -LiteralPath $rmLog -Force
$env:CC_CODEX_FAKE_DOCKER_MODE = 'foreign'
Assert-Throws { Remove-OwnedDockerContainer -DockerCommand $fakeDocker -ContainerId 'foreign123' -Identity $identityA | Out-Null }
if (Test-Path -LiteralPath $rmLog) { throw 'Foreign container cleanup was attempted.' }

Remove-Item -LiteralPath $fakeDocker -Force

$failureDocker = Join-Path $tempRoot "cc-codex-failure-docker-$([Guid]::NewGuid().ToString('N')).ps1"
$failureOutputRoot = Join-Path $tempRoot "cc-codex-runtime-finalization-$([Guid]::NewGuid().ToString('N'))"
$failureRunId = 'ci-cleanup-failure'
$failureRepositoryRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$failureRuntimeDirectory = Join-Path $failureRepositoryRoot 'tests/runtime'
$failureSource = Get-SourceIdentity -RepositoryRoot $failureRepositoryRoot -RuntimeDirectory $failureRuntimeDirectory
$failureIdentity = Get-RunIdentity -RepositoryRoot $failureRepositoryRoot -RuntimeDirectory $failureRuntimeDirectory -RunId $failureRunId -OutputRoot $failureOutputRoot -Source $failureSource
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$command = $Arguments[0]
if ($command -eq 'build') { exit 0 }
if ($command -eq 'create') {
    Write-Output ('a' * 64)
    exit 0
}
if ($command -eq 'start') {
    $summary = @{
        schema = 2
        status = 'passed'
        failed = 0
        passed = 1
        integration = @{ status = 'passed'; elapsed_ms = 1; passed = 1; failed = 0 }
        lua_suite = @{ status = 'passed'; elapsed_ms = 1; total = 1; passed = 1; failed = 0; failure_details = @{} }
        total_elapsed_ms = 2
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $env:CC_CODEX_TEST_OUTPUT_PATH 'cc-summary.json') -Encoding utf8
    @{ schema = 1; container_elapsed_ms = 1 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:CC_CODEX_TEST_OUTPUT_PATH 'container-timing.json') -Encoding utf8
    exit 0
}
if ($command -eq 'inspect') {
    Write-Output ('{"cc-codex.owner":"runtime-fixture","cc-codex.scope":"' + $env:CC_CODEX_TEST_SCOPE + '","cc-codex.run":"' + $env:CC_CODEX_TEST_RUN + '","cc-codex.source":"' + $env:CC_CODEX_TEST_SOURCE + '"}')
    exit 0
}
if ($command -eq 'rm') {
    Add-Content -LiteralPath $env:CC_CODEX_TEST_CLEANUP_LOG -Value 'cleanup-attempted'
    exit 7
}
exit 0
'@ | Set-Content -LiteralPath $failureDocker -Encoding utf8

$savedTestOutput = [Environment]::GetEnvironmentVariable('CC_CODEX_TEST_OUTPUT_PATH')
$savedTestScope = [Environment]::GetEnvironmentVariable('CC_CODEX_TEST_SCOPE')
$savedTestRun = [Environment]::GetEnvironmentVariable('CC_CODEX_TEST_RUN')
$savedTestSource = [Environment]::GetEnvironmentVariable('CC_CODEX_TEST_SOURCE')
$savedTestCleanupLog = [Environment]::GetEnvironmentVariable('CC_CODEX_TEST_CLEANUP_LOG')
$cleanupLog = Join-Path $failureOutputRoot 'cleanup.log'
try {
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_OUTPUT_PATH', $failureIdentity.output_path)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_SCOPE', $failureIdentity.scope_key)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_RUN', $failureIdentity.run_id)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_SOURCE', $failureIdentity.source_sha)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_CLEANUP_LOG', $cleanupLog)
    $powerShell = 'pwsh'
    $runScript = Join-Path $PSScriptRoot 'run.ps1'
    $failureOutput = & $powerShell -NoProfile -File $runScript -OutputPath $failureOutputRoot -RunId $failureRunId -DockerCommand $failureDocker 2>&1
    $failureExitCode = $LASTEXITCODE
    if ($failureExitCode -eq 0) { throw 'Runtime runner returned success after owned-container cleanup failed.' }
    $failureManifestPath = Join-Path $failureIdentity.output_path 'run-manifest.json'
    if (-not (Test-Path -LiteralPath $failureManifestPath)) { throw "Failed runtime did not preserve its manifest. Exit code: $failureExitCode; output: $($failureOutput -join "`n")" }
    $failureManifest = Get-Content -Raw -LiteralPath $failureManifestPath | ConvertFrom-Json
    if ($failureManifest.status -ne 'failed' -or [int]$failureManifest.exit_code -ne 1) { throw 'Cleanup failure did not produce a failed manifest with exit code 1.' }
    if ($failureManifest.failure -notmatch 'cleanup failed') { throw 'Cleanup failure was not preserved in the final manifest.' }
    if ($null -eq $failureManifest.evidence -or [string]::IsNullOrWhiteSpace($failureManifest.evidence.output_sha256)) { throw 'Failed manifest did not preserve output evidence.' }
    if (-not (Test-Path -LiteralPath (Join-Path $failureIdentity.output_path 'runtime-evidence.json'))) { throw 'Failed run lost runtime evidence.' }
    if ((Get-Content -Raw -LiteralPath $cleanupLog).Trim() -ne 'cleanup-attempted') { throw 'Cleanup failure regression did not exercise the owned cleanup path.' }
    if (($failureOutput -join "`n") -match 'Passed \d+ CC runtime checks') { throw 'Failed runtime was reported as passed.' }
}
finally {
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_OUTPUT_PATH', $savedTestOutput)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_SCOPE', $savedTestScope)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_RUN', $savedTestRun)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_SOURCE', $savedTestSource)
    [Environment]::SetEnvironmentVariable('CC_CODEX_TEST_CLEANUP_LOG', $savedTestCleanupLog)
    if (Test-Path -LiteralPath $failureDocker) { Remove-Item -LiteralPath $failureDocker -Force }
    if (Test-Path -LiteralPath $failureOutputRoot) { Remove-Item -LiteralPath $failureOutputRoot -Recurse -Force }
}

Write-Host 'Runtime fixture isolation host tests passed.'
