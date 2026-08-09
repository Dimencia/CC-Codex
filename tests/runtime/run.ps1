[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$RunId,
    [int]$TimeoutSeconds = 180,
    [string]$DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'run-support.ps1')

if ($TimeoutSeconds -le 0) { throw '-TimeoutSeconds must be greater than zero.' }
if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "local-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
}
Assert-ValidRunId -RunId $RunId

$repositoryRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$runtimeDirectory = Join-Path $repositoryRoot 'tests/runtime'
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $runtimeDirectory 'output' }
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$source = Get-SourceIdentity -RepositoryRoot $repositoryRoot -RuntimeDirectory $runtimeDirectory
$identity = Get-RunIdentity -RepositoryRoot $repositoryRoot -RuntimeDirectory $runtimeDirectory -RunId $RunId -OutputRoot $outputRoot -Source $source
if (Test-Path -LiteralPath $identity.output_path) {
    $existing = @(Get-ChildItem -LiteralPath $identity.output_path -Force)
    if ($existing.Count -gt 0) { throw "Run output '$($identity.output_path)' already exists; refusing to reuse or delete it." }
}
New-Item -ItemType Directory -Force -Path $identity.output_path | Out-Null
$manifestPath = Join-Path $identity.output_path 'run-manifest.json'
Write-RunManifest -Path $manifestPath -Identity $identity -Status 'created' -ExitCode 0

$dockerfilePath = Join-Path $runtimeDirectory 'Dockerfile'
$containerId = $null
$exitCode = 0
$failure = $null
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$fixtureStopwatch = $null

try {
    $buildLabels = @(
        '--label', 'cc-codex.owner=runtime-fixture',
        '--label', "cc-codex.scope=$($identity.scope_key)",
        '--label', "cc-codex.source=$($identity.source_sha)"
    )
    Write-Host "Building $($identity.image_name) for source $($identity.source_sha)..."
    & $DockerCommand build --file $dockerfilePath --tag $identity.image_name @buildLabels $repositoryRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker image build failed with exit code $LASTEXITCODE." }
    $buildStopwatch.Stop()

    $dockerArguments = @(
        'create', '--rm', '--name', $identity.container_name,
        '--label', 'cc-codex.owner=runtime-fixture',
        '--label', "cc-codex.scope=$($identity.scope_key)",
        '--label', "cc-codex.run=$($identity.run_id)",
        '--label', "cc-codex.source=$($identity.source_sha)",
        '--mount', "type=bind,source=$($identity.output_path),destination=/output",
        '--env', "CC_CODEX_TIMEOUT_SECONDS=$TimeoutSeconds",
        $identity.image_name
    )
    $containerId = (& $DockerCommand @dockerArguments).Trim()
    if ($LASTEXITCODE -ne 0 -or $containerId -notmatch '^[0-9a-f]+$') { throw 'Docker did not return a valid captured container ID.' }
    $identity | Add-Member -NotePropertyName container_id -NotePropertyValue $containerId -Force
    Write-RunManifest -Path $manifestPath -Identity $identity -Status 'running' -ExitCode 0

    Write-Host "Running the real NeoForge/CC:Tweaked fixture in $($identity.container_name)..."
    $fixtureStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    & $DockerCommand start --attach $containerId
    $exitCode = $LASTEXITCODE
    $fixtureStopwatch.Stop()
    if ($exitCode -ne 0) { throw "Runtime integration container failed with exit code $exitCode. See $($identity.output_path)." }

    $summaryPath = Join-Path $identity.output_path 'cc-summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { throw "Runtime integration completed without $summaryPath." }
    $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    if ($summary.status -ne 'passed') { throw "Runtime integration reported status '$($summary.status)'." }
    if ($null -eq $summary.lua_suite -or $summary.lua_suite.status -ne 'passed') { throw "The in-game Lua suite did not pass. See $($identity.output_path)." }
    $luaTestTotal = [int]$summary.lua_suite.total
    if ($luaTestTotal -le 0) { throw 'The in-game Lua suite did not report any executed tests.' }
    if ([int]$summary.lua_suite.passed -ne $luaTestTotal -or [int]$summary.lua_suite.failed -ne 0) {
        throw "The in-game Lua suite reported $($summary.lua_suite.passed) passed and $($summary.lua_suite.failed) failed out of $luaTestTotal tests."
    }

    $containerElapsedMilliseconds = $null
    $containerTimingPath = Join-Path $identity.output_path 'container-timing.json'
    if (Test-Path -LiteralPath $containerTimingPath) {
        $containerTiming = Get-Content -Raw -LiteralPath $containerTimingPath | ConvertFrom-Json
        if ($null -ne $containerTiming.container_elapsed_ms) { $containerElapsedMilliseconds = [int64]$containerTiming.container_elapsed_ms }
    }
    $timing = [ordered]@{
        schema = 1
        source_sha = $identity.source_sha
        run_id = $identity.run_id
        host_build_elapsed_ms = [math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
        host_fixture_elapsed_ms = [math]::Round($fixtureStopwatch.Elapsed.TotalMilliseconds)
        host_total_elapsed_ms = [math]::Round($buildStopwatch.Elapsed.TotalMilliseconds + $fixtureStopwatch.Elapsed.TotalMilliseconds)
        container_elapsed_ms = $containerElapsedMilliseconds
        guest_lua_suite_elapsed_ms = [int64]$summary.lua_suite.elapsed_ms
        guest_integration_elapsed_ms = [int64]$summary.integration.elapsed_ms
        guest_total_elapsed_ms = [int64]$summary.total_elapsed_ms
    }
    $timingPath = Join-Path $identity.output_path 'runtime-timing.json'
    $timing | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $timingPath -Encoding utf8
    $evidence = Get-OutputEvidence -OutputPath $identity.output_path
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $identity.output_path 'runtime-evidence.json') -Encoding utf8
    Write-RunManifest -Path $manifestPath -Identity $identity -Status 'passed' -ExitCode 0 -Evidence $evidence
}
catch {
    $failure = $_.Exception.Message
    if ($exitCode -eq 0) { $exitCode = 1 }
    throw
}
finally {
    if ($null -ne $fixtureStopwatch -and $fixtureStopwatch.IsRunning) { $fixtureStopwatch.Stop() }
    if ($null -ne $containerId) {
        try { $cleanup = Remove-OwnedDockerContainer -DockerCommand $DockerCommand -ContainerId $containerId -Identity $identity } catch { if ($null -eq $failure) { $failure = $_.Exception.Message }; $exitCode = 1 }
    }
    if ($null -ne $identity.output_path -and (Test-Path -LiteralPath $identity.output_path)) {
        try {
            Write-RunManifest -Path $manifestPath -Identity $identity -Status ($(if ($exitCode -eq 0) { 'passed' } else { 'failed' })) -ExitCode $exitCode -Failure $failure -Evidence $(if (Test-Path -LiteralPath (Join-Path $identity.output_path 'runtime-evidence.json')) { Get-Content -Raw -LiteralPath (Join-Path $identity.output_path 'runtime-evidence.json') | ConvertFrom-Json } else { $null })
        } catch {
            $manifestFailure = $_.Exception.Message
            if ($null -eq $failure) { $failure = $manifestFailure }
            $exitCode = 1
            Write-Warning "Could not finalize runtime manifest: $manifestFailure"
        }
    }
}

if ($exitCode -ne 0) {
    if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'Runtime integration finalization failed.' }
    throw $failure
}

Write-Host ("Passed {0} CC runtime checks and {1} Lua tests; output: {2}" -f $summary.passed, $summary.lua_suite.passed, $identity.output_path)
