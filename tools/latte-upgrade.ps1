# Start a latte upgrade that runs after latte.cmd exits: Windows will not move a
# directory holding a running file, so the installer waits for the launcher's PID.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Prefix,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $Prefix 'libexec\latte-install.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    Write-Error 'latte: error: this installation has no upgrade helper'
    exit 1
}

try {
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
} catch {
    Write-Error 'latte: error: cannot find the latte launcher process'
    exit 1
}

# A copy, so the installer is not itself a file inside the directory it replaces.
$copy = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("latte-upgrade-" + [System.Guid]::NewGuid().ToString('N') + '.ps1')
Copy-Item -LiteralPath $source -Destination $copy -Force

function Quote-ProcessArgument([string] $Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

$engine = (Get-Process -Id $PID).Path
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Quote-ProcessArgument $copy),
    '-Prefix', (Quote-ProcessArgument $Prefix),
    '-NoModifyPath',
    '-WaitForPid', "$parent"
)
if ($Force) { $arguments += '-Force' }

Start-Process -FilePath $engine -ArgumentList ($arguments -join ' ') -NoNewWindow | Out-Null
Write-Host 'latte: upgrade started; it finishes after this command exits'
