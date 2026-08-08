[CmdletBinding()]
param(
    [string]$AtmonsJar,
    [switch]$RequireAtmons,
    [string]$OutputPath,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

if ($TimeoutSeconds -le 0) {
    throw "-TimeoutSeconds must be greater than zero."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot "tests\runtime\output"
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null

foreach ($stalePath in @(
    (Join-Path $outputFullPath "computer-fs"),
    (Join-Path $outputFullPath "cc-summary.json"),
    (Join-Path $outputFullPath "server-console.log"),
    (Join-Path $outputFullPath "server-latest.log")
)) {
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Recurse -Force
    }
}

$atmonsFullPath = $null
if (-not [string]::IsNullOrWhiteSpace($AtmonsJar)) {
    $atmonsFullPath = (Resolve-Path -LiteralPath $AtmonsJar).Path
} elseif ($RequireAtmons) {
    throw "-RequireAtmons needs -AtmonsJar pointing to a built ATMons jar."
}

$imageName = "cc-codex-runtime-smoke:local"
$buildContext = Join-Path $repositoryRoot "tests\runtime"
$requireAtmonsValue = if ($RequireAtmons) { "1" } else { "0" }

Write-Host "Building $imageName..."
& docker build --tag $imageName $buildContext
if ($LASTEXITCODE -ne 0) {
    throw "Docker image build failed with exit code $LASTEXITCODE."
}

$dockerArguments = @(
    "run",
    "--rm",
    "--name",
    "cc-codex-runtime-smoke",
    "--mount",
    "type=bind,source=$outputFullPath,destination=/output",
    "--env",
    "REQUIRE_ATMONS=$requireAtmonsValue",
    "--env",
    "CC_CODEX_TIMEOUT_SECONDS=$TimeoutSeconds"
)
if ($null -ne $atmonsFullPath) {
    $dockerArguments += @(
        "--mount",
        "type=bind,source=$atmonsFullPath,destination=/input/anomaly.jar,readonly"
    )
}
$dockerArguments += $imageName

Write-Host "Running the real NeoForge/CC:Tweaked fixture..."
& docker @dockerArguments
$containerExit = $LASTEXITCODE
if ($containerExit -ne 0) {
    throw "Runtime smoke container failed with exit code $containerExit. See $outputFullPath."
}

$summaryPath = Join-Path $outputFullPath "cc-summary.json"
if (-not (Test-Path -LiteralPath $summaryPath)) {
    throw "Runtime smoke completed without $summaryPath."
}

$summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
if ($summary.status -ne "passed") {
    throw "Runtime smoke reported status '$($summary.status)'."
}

Write-Host ("Passed {0} CC runtime checks; output: {1}" -f $summary.passed, $outputFullPath)
