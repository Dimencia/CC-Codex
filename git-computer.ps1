[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Status', 'Initialize', 'FetchToRepository')]
    [string] $Action = 'Status',

    [ValidateRange(0, [int]::MaxValue)]
    [int] $ComputerNumber = 3,

    [string] $Branch = 'codex/computer-3-work'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$computerRoot = 'C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer'
$computerPath = Join-Path $computerRoot ([string] $ComputerNumber)
$repoRoot = $PSScriptRoot
$remoteName = 'computer-{0}' -f $ComputerNumber

if (-not (Test-Path -LiteralPath $computerPath -PathType Container)) {
    throw "Computer directory does not exist: $computerPath"
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    & git -c ("safe.directory={0}" -f $WorkingDirectory) -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed in '$WorkingDirectory': git $($Arguments -join ' ')"
    }
}

function Test-GitCheckout {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $null = & git -c ("safe.directory={0}" -f $Path) -C $Path rev-parse --is-inside-work-tree 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

if ($Action -eq 'Status') {
    if (-not (Test-GitCheckout -Path $computerPath)) {
        Write-Output "Computer $ComputerNumber is not initialized as a Git checkout: $computerPath"
        return
    }
    Invoke-Git -WorkingDirectory $computerPath -Arguments @('status', '--short', '--branch')
    return
}

if ($Action -eq 'Initialize') {
    if (Test-GitCheckout -Path $computerPath) {
        throw "Computer $ComputerNumber already has a Git checkout."
    }
    if (-not $PSCmdlet.ShouldProcess($computerPath, "Initialize Git branch '$Branch' and record the current source tree")) {
        return
    }

    $ignorePath = Join-Path $computerPath '.gitignore'
    $ignoreText = @(
        '.settings'
        'data/codex-state.json'
        'data/preferences.md'
        'data/usage.jsonl'
        'data/tools.jsonl'
        'data/host-command-*.json*'
        'data/conversations/'
        'data/*.tmp'
        'artifacts/'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($ignorePath, $ignoreText + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

    Invoke-Git -WorkingDirectory $computerPath -Arguments @('init', '-b', $Branch)
    Invoke-Git -WorkingDirectory $computerPath -Arguments @('add', '--all')
    Invoke-Git -WorkingDirectory $computerPath -Arguments @('commit', '-m', "Initialize computer $ComputerNumber CC Codex checkout")
    Write-Output "Initialized computer $ComputerNumber on branch '$Branch'. Settings and runtime data remain untracked/ignored."
    return
}

if (-not (Test-GitCheckout -Path $computerPath)) {
    throw "Computer $ComputerNumber is not initialized as a Git checkout."
}

if ($Action -eq 'FetchToRepository') {
    $remoteUrl = $null
    $remoteExists = $true
    try {
        $remoteUrl = (& git -c ("safe.directory={0}" -f $repoRoot) -C $repoRoot remote get-url $remoteName 2>$null)
        $remoteExists = $LASTEXITCODE -eq 0
    } catch {
        $remoteExists = $false
    }
    if (-not $remoteExists) {
        if (-not $PSCmdlet.ShouldProcess($repoRoot, "Add Git remote '$remoteName' pointing to computer $ComputerNumber")) {
            return
        }
        Invoke-Git -WorkingDirectory $repoRoot -Arguments @('remote', 'add', $remoteName, $computerPath)
    } elseif ($remoteUrl.Trim() -ne $computerPath) {
        throw "Git remote '$remoteName' already points to '$($remoteUrl.Trim())', not '$computerPath'."
    }

    if (-not $PSCmdlet.ShouldProcess($repoRoot, "Fetch branch '$Branch' from computer $ComputerNumber")) {
        return
    }
    Invoke-Git -WorkingDirectory $repoRoot -Arguments @('fetch', '--no-tags', $remoteName, $Branch)
    Write-Output "Fetched '$remoteName/$Branch'. Review the commit graph, then use normal Git merge when ready."
}
