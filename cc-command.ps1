[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Lua')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Lua')]
    [AllowEmptyString()]
    [string] $Code,

    [Parameter(Mandatory = $true, ParameterSetName = 'Restart')]
    [switch] $Restart,

    [ValidateRange(0, [int]::MaxValue)]
    [int] $ComputerNumber = 3,

    [ValidateRange(1, [int]::MaxValue)]
    [int] $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSCmdlet.ParameterSetName -eq 'Lua' -and [string]::IsNullOrWhiteSpace($Code)) {
    throw 'Code must not be blank.'
}

$computerRoot = 'C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer'
$computerPath = Join-Path $computerRoot ([string] $ComputerNumber)
$dataPath = Join-Path $computerPath 'data'
$requestPath = Join-Path $dataPath 'host-command-request.json'
$requestTemporaryPath = $requestPath + '.tmp'
$resultPath = Join-Path $dataPath 'host-command-result.json'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
$action = if ($PSCmdlet.ParameterSetName -eq 'Restart') { 'restart' } else { 'lua' }

if (-not (Test-Path -LiteralPath $dataPath -PathType Container)) {
    throw "CC Codex data directory does not exist on computer $ComputerNumber."
}

if (-not $PSCmdlet.ShouldProcess($requestPath, "Publish $action host command")) {
    return
}

function Wait-UntilRequestSlotIsFree {
    while (Test-Path -LiteralPath $requestPath) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'Timed out waiting for CC Codex to consume the prior host command.'
        }
        Start-Sleep -Milliseconds 100
    }
}

function Publish-Request {
    param(
        [Parameter(Mandatory = $true)][string] $RequestId
    )

    Wait-UntilRequestSlotIsFree
    $request = [ordered]@{ id = $RequestId; action = $action }
    if ($action -eq 'lua') { $request.code = $Code }
    $json = $request | ConvertTo-Json -Compress

    [System.IO.File]::WriteAllText($requestTemporaryPath, $json, $utf8WithoutBom)
    try {
        [System.IO.File]::Move($requestTemporaryPath, $requestPath)
    } catch {
        if (Test-Path -LiteralPath $requestTemporaryPath) {
            Remove-Item -LiteralPath $requestTemporaryPath -Force
        }
        throw
    }
}

function Wait-MatchingResult {
    param(
        [Parameter(Mandatory = $true)][string] $RequestId
    )

    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            try {
                $candidate = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
                $idProperty = $candidate.PSObject.Properties['id']
                if ($null -ne $idProperty -and [string] $idProperty.Value -eq $RequestId) {
                    return $candidate
                }
            } catch {
                # The CC side publishes by rename, but tolerate a transient read
                # failure without exposing request contents or abandoning the wait.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for CC Codex host command result after $TimeoutSeconds seconds."
}

while ($true) {
    $requestId = [Guid]::NewGuid().ToString('N')
    Publish-Request -RequestId $requestId
    $result = Wait-MatchingResult -RequestId $requestId

    $errorCodeProperty = $result.PSObject.Properties['error_code']
    $isBusy = $action -eq 'restart'
        -and $null -ne $errorCodeProperty
        -and [string] $errorCodeProperty.Value -eq 'busy'
    if ($isBusy) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for CC Codex to become idle after $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 250
    } else {
        Write-Output ($result | ConvertTo-Json -Compress -Depth 10)
        return
    }
}
