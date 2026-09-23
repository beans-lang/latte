# Install latte for the current user with built-in PowerShell and .NET only:
#   irm https://github.com/beans-lang/latte/releases/latest/download/latte-install.ps1 | iex

[CmdletBinding()]
param(
    [string] $Version,
    [string] $Prefix,
    [string] $Target,
    [switch] $Force,
    [switch] $NoModifyPath,
    [switch] $Help,
    [int] $WaitForPid
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The launcher's self-upgrade passes its own PID, so no file it holds open is moved.
if ($WaitForPid -gt 0) {
    try { Wait-Process -Id $WaitForPid -ErrorAction SilentlyContinue } catch { }
}

$Repo = if ($env:LATTE_INSTALL_REPO) { $env:LATTE_INSTALL_REPO } else { 'beans-lang/latte' }

function Write-Note([string] $Message) { Write-Host "latte: $Message" }
function Die([string] $Message) { Write-Error "latte: error: $Message"; exit 1 }

# .NET rather than Get-FileHash, which PowerShell 3 does not have.
function Get-Sha256([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    $text = New-Object System.Text.StringBuilder
    foreach ($byte in $digest) { [void]$text.Append($byte.ToString('x2')) }
    return $text.ToString()
}

# ZipFile rather than Expand-Archive, which PowerShell 5 introduced.
function Expand-Zip([string] $Archive, [string] $Destination) {
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

# `irm | iex` passes no parameters, so the environment is that entry point's.
if (-not $Prefix -and $env:LATTE_HOME) { $Prefix = $env:LATTE_HOME }
if (-not $Target -and $env:LATTE_TARGET) { $Target = $env:LATTE_TARGET }
if (-not $Force -and $env:LATTE_INSTALL_FORCE -eq '1') { $Force = $true }
if (-not $NoModifyPath -and $env:LATTE_INSTALL_NO_MODIFY_PATH -eq '1') { $NoModifyPath = $true }
if ($Version) { $Version = $Version.TrimStart('v') }

if ($Help) {
    @'
usage: latte-install.ps1 [options]

  -Version <v>      install this release instead of the latest (e.g. 0.2.0)
  -Prefix <dir>     install here instead of %LOCALAPPDATA%\Latte
  -Target <triple>  force a target instead of detecting one
  -Force            reinstall even when this version is already installed
  -NoModifyPath     do not touch the user PATH
  -Help             show this message

environment:
  LATTE_HOME        same as -Prefix
  LATTE_TARGET      same as -Target
'@ | Write-Host
    exit 0
}

if (-not $Prefix) {
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = Join-Path $env:USERPROFILE 'AppData\Local' }
    $Prefix = Join-Path $localAppData 'Latte'
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("latte-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # -------------------------------------------------------------- platform
    $machine = $env:PROCESSOR_ARCHITECTURE
    try {
        $machine = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch { }
    if (-not $Target) {
        switch -Regex ($machine) {
            '^(X64|AMD64)$' { $Target = 'x86_64-pc-windows-gnullvm' }
        }
    }

    # ------------------------------------------------------------- checksums
    $base = $env:LATTE_INSTALL_BASE_URL
    $baseIsOurs = $false
    if (-not $base) {
        $baseIsOurs = $true
        if ($Version) {
            $base = "https://github.com/$Repo/releases/download/v$Version"
        } else {
            $base = "https://github.com/$Repo/releases/latest/download"
        }
    }

    # A bare path is how CI runs this end to end before a release exists.
    function Get-Asset([string] $From, [string] $To) {
        if ($From -match '^https?://') {
            Invoke-WebRequest -Uri $From -OutFile $To -UseBasicParsing
        } else {
            if (-not (Test-Path -LiteralPath $From)) { throw "no such file: $From" }
            Copy-Item -LiteralPath $From -Destination $To -Force
        }
    }

    $sums = Join-Path $work 'SHA256SUMS'
    try { Get-Asset "$base/SHA256SUMS" $sums } catch {
        Die "cannot download the release's checksums from $base/SHA256SUMS"
    }

    $asset = $null
    $expected = $null
    if ($Target) {
        foreach ($line in Get-Content -LiteralPath $sums) {
            $fields = $line -split '\s+', 2
            if ($fields.Count -lt 2) { continue }
            $name = $fields[1].TrimStart('*').Trim()
            if ($name.StartsWith('latte-v') -and $name.EndsWith("-$Target.zip")) {
                $asset = $name; $expected = $fields[0]; break
            }
        }
    }
    if (-not $asset) {
        Write-Host "latte: no released package matches this machine ($machine, target '$Target')." -ForegroundColor Red
        Write-Host "Published packages:"
        foreach ($line in Get-Content -LiteralPath $sums) {
            $fields = $line -split '\s+', 2
            if ($fields.Count -ge 2) { Write-Host "  $($fields[1].TrimStart('*'))" }
        }
        exit 1
    }
    $releaseVersion = $asset.Substring('latte-v'.Length)
    $releaseVersion = $releaseVersion.Substring(0, $releaseVersion.Length - "-$Target.zip".Length)
    if ($Version -and $Version -ne $releaseVersion) {
        Die "the release at $base publishes $releaseVersion, not $Version"
    }
    if ($baseIsOurs) { $base = "https://github.com/$Repo/releases/download/v$releaseVersion" }

    # ----------------------------------------------------- already installed
    $launcher = Join-Path $Prefix 'bin\latte.cmd'
    if (-not $Force -and (Test-Path -LiteralPath $launcher)) {
        $installed = ''
        try { $installed = (& $launcher version 2>$null) -join ' ' } catch { }
        if ($installed -eq "latte $releaseVersion") {
            Write-Note "latte $releaseVersion is already installed in $Prefix"
            Write-Note "re-run with -Force to reinstall"
            exit 0
        }
    }

    # -------------------------------------------------------------- download
    Write-Note "downloading $asset"
    $archive = Join-Path $work $asset
    try { Get-Asset "$base/$asset" $archive } catch { Die "cannot download $base/$asset" }
    $actual = Get-Sha256 $archive
    if ($actual -ne $expected.ToLowerInvariant()) {
        Die "checksum mismatch for $asset`n  expected $expected`n  actual   $actual`nNothing was installed."
    }
    Write-Note "checksum verified"

    # --------------------------------------------------- unpack and validate
    $stage = Join-Path $work 'stage'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try { Expand-Zip $archive $stage } catch { Die "cannot unpack $asset; nothing was installed" }
    $unpacked = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
    if (-not $unpacked) { Die "$asset does not contain a package directory" }
    $stagedLauncher = Join-Path $unpacked.FullName 'bin\latte.cmd'
    if (-not (Test-Path -LiteralPath $stagedLauncher)) { Die "$asset has no bin\latte.cmd; nothing was installed" }
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked.FullName 'share\latte\VERSION'))) {
        Die "$asset has no page kit (share\latte\VERSION); nothing was installed"
    }
    $stagedVersion = ''
    try { $stagedVersion = (& $stagedLauncher version 2>$null) -join ' ' } catch { }
    if ($stagedVersion -ne "latte $releaseVersion") {
        Die "the downloaded latte said '$stagedVersion', not 'latte $releaseVersion'; nothing was installed"
    }
    Write-Note "staged $stagedVersion"

    # --------------------------------------------------------------- install
    $parent = Split-Path -Parent $Prefix
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $previous = $null
    if (Test-Path -LiteralPath $Prefix) {
        $previous = "$Prefix.old-$PID"
        Move-Item -LiteralPath $Prefix -Destination $previous
    }
    try {
        Move-Item -LiteralPath $unpacked.FullName -Destination $Prefix
    } catch {
        if ($previous) { Move-Item -LiteralPath $previous -Destination $Prefix }
        Die "cannot install into $Prefix"
    }
    if ($previous) { Remove-Item -Recurse -Force $previous -ErrorAction SilentlyContinue }

    # ------------------------------------------------------------------ PATH
    $binDir = Join-Path $Prefix 'bin'
    if (-not $NoModifyPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $userPath) { $userPath = '' }
        $entries = $userPath -split ';' | Where-Object { $_ -ne '' }
        $already = $entries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
        if (-not $already) {
            [Environment]::SetEnvironmentVariable('Path', ((@($binDir) + $entries) -join ';'), 'User')
            Write-Note "PATH updated for your user account; open a new terminal"
        }
    }

    Write-Host ""
    Write-Note "installed latte $releaseVersion into $Prefix"
    $env:Path = "$binDir;$env:Path"
    & $launcher version
    if ($LASTEXITCODE -ne 0) { Die "the installed latte did not run" }
    Write-Note "run 'latte doctor' to see what this machine can build"
    Write-Note "move a project to this latte with 'latte upgrade --project' inside it"
} finally {
    if ($work -and (Test-Path $work)) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}
