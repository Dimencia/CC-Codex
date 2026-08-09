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
Assert-Throws { Assert-PathWithinRoot -Path (Join-Path $outputRoot '..\foreign') -Root $outputRoot }

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
Write-Host 'Runtime fixture isolation host tests passed.'
