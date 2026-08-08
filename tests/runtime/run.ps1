[CmdletBinding()]
param(
    [string]$OutputPath,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

if ($TimeoutSeconds -le 0) {
    throw "-TimeoutSeconds must be greater than zero."
}

$repositoryRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot "..") "..")).Path
$runtimeDirectory = Join-Path (Join-Path $repositoryRoot "tests") "runtime"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $runtimeDirectory "output"
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null

foreach ($stalePath in @(
    (Join-Path $outputFullPath "computer-fs"),
    (Join-Path $outputFullPath "world-debug"),
    (Join-Path $outputFullPath "cc-summary.json"),
    (Join-Path $outputFullPath "server-console.log"),
    (Join-Path $outputFullPath "server-latest.log"),
    (Join-Path $outputFullPath "runtime-timing.json")
)) {
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Recurse -Force
    }
}

$imageName = "cc-codex-runtime-integration:local"
$dockerfilePath = Join-Path $runtimeDirectory "Dockerfile"
$buildContext = $repositoryRoot

Write-Host "Building $imageName..."
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& docker build --file $dockerfilePath --tag $imageName $buildContext
$buildStopwatch.Stop()
if ($LASTEXITCODE -ne 0) {
    throw "Docker image build failed with exit code $LASTEXITCODE."
}

$dockerArguments = @(
    "run",
    "--rm",
    "--name",
    "cc-codex-runtime-integration",
    "--mount",
    "type=bind,source=$outputFullPath,destination=/output",
    "--env",
    "CC_CODEX_TIMEOUT_SECONDS=$TimeoutSeconds"
)
$dockerArguments += $imageName

Write-Host "Running the real NeoForge/CC:Tweaked fixture..."
$fixtureStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& docker @dockerArguments
$containerExit = $LASTEXITCODE
$fixtureStopwatch.Stop()
if ($containerExit -ne 0) {
    throw "Runtime integration container failed with exit code $containerExit. See $outputFullPath."
}

$summaryPath = Join-Path $outputFullPath "cc-summary.json"
if (-not (Test-Path -LiteralPath $summaryPath)) {
    throw "Runtime integration completed without $summaryPath."
}

$summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
if ($summary.status -ne "passed") {
    throw "Runtime integration reported status '$($summary.status)'."
}
if ($null -eq $summary.lua_suite -or $summary.lua_suite.status -ne "passed") {
    throw "The in-game Lua suite did not pass. See $outputFullPath."
}
$luaTestTotal = [int]$summary.lua_suite.total
if ($luaTestTotal -le 0) {
    throw "The in-game Lua suite did not report any executed tests."
}
if ([int]$summary.lua_suite.passed -ne $luaTestTotal -or [int]$summary.lua_suite.failed -ne 0) {
    throw "The in-game Lua suite reported $($summary.lua_suite.passed) passed and $($summary.lua_suite.failed) failed out of $luaTestTotal tests."
}

$containerElapsedMilliseconds = $null
$timingPath = Join-Path $outputFullPath "runtime-timing.json"
if (Test-Path -LiteralPath $timingPath) {
    $containerTiming = Get-Content -Raw -LiteralPath $timingPath | ConvertFrom-Json
    if ($null -ne $containerTiming.container_elapsed_ms) {
        $containerElapsedMilliseconds = [int64]$containerTiming.container_elapsed_ms
    }
}
$timing = [ordered]@{
    schema = 1
    host_build_elapsed_ms = [math]::Round($buildStopwatch.Elapsed.TotalMilliseconds)
    host_fixture_elapsed_ms = [math]::Round($fixtureStopwatch.Elapsed.TotalMilliseconds)
    host_total_elapsed_ms = [math]::Round($buildStopwatch.Elapsed.TotalMilliseconds + $fixtureStopwatch.Elapsed.TotalMilliseconds)
    container_elapsed_ms = $containerElapsedMilliseconds
    guest_lua_suite_elapsed_ms = [int64]$summary.lua_suite.elapsed_ms
    guest_integration_elapsed_ms = [int64]$summary.integration.elapsed_ms
    guest_total_elapsed_ms = [int64]$summary.total_elapsed_ms
}
$timing | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $timingPath -Encoding utf8

Write-Host ("Passed {0} CC runtime checks and {1} Lua tests; guest fixture {2:N1}s (suite {3:N1}s); host total {4:N1}s; output: {5}" -f `
    $summary.passed,
    $summary.lua_suite.passed,
    ([double]$summary.total_elapsed_ms / 1000),
    ([double]$summary.lua_suite.elapsed_ms / 1000),
    (($buildStopwatch.Elapsed.TotalMilliseconds + $fixtureStopwatch.Elapsed.TotalMilliseconds) / 1000),
    $outputFullPath)
