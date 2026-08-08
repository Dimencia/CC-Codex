$ErrorActionPreference = 'Stop'

$server = 'C:\Users\Dimen\.vscode\extensions\sumneko.lua-3.18.2-win32-x64\server\bin\lua-language-server.exe'
if (-not (Test-Path -LiteralPath $server)) {
    throw 'Lua Language Server 3.18.2 was not found in the expected VS Code extension path.'
}

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$toolState = Join-Path $workspace '.lua-language-server'
New-Item -ItemType Directory -Force -Path $toolState | Out-Null

& $server `
    --check=$workspace `
    --check_format=pretty `
    --checklevel=Warning `
    --configpath=.luarc.json `
    --logpath=(Join-Path $toolState 'log') `
    --metapath=(Join-Path $toolState 'meta')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
