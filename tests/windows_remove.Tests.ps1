param(
    [Parameter(Mandatory = $true)]
    [string]$ZigupExe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "assertion failed: $Name" }
    $script:Assertions++
}

function Invoke-Zigup([string[]]$Arguments) {
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 wraps native stderr as NativeCommandError.
        # Capture it as ordinary diagnostic text without making it terminating.
        $ErrorActionPreference = 'Continue'
        $output = (& $ZigupExe @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

$zigupPath = [IO.Path]::GetFullPath($ZigupExe)
Assert-True ([IO.File]::Exists($zigupPath)) 'zigup test executable exists'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('zigup-remove-test-' + [guid]::NewGuid().ToString('N'))
$hadHome = Test-Path Env:ZIGUP_HOME
$oldHome = $env:ZIGUP_HOME
$targetProcess = $null
$unrelatedProcess = $null
$fileOwner = $null
$heldFile = $null
try {
    $env:ZIGUP_HOME = $testRoot
    $version = '1.2.3-force-test'
    $toolchain = Join-Path $testRoot "toolchains\$version"
    [IO.Directory]::CreateDirectory($toolchain) | Out-Null
    $testZig = Join-Path $toolchain 'zig.exe'
    $systemPing = Join-Path $env:SystemRoot 'System32\ping.exe'
    [IO.File]::Copy($systemPing, $testZig, $false)
    $sentinel = Join-Path $toolchain 'sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'must survive a refused removal')

    $result = Invoke-Zigup @('add', $version, $testZig)
    Assert-True ($result.Code -eq 0) 'register managed test toolchain'
    $result = Invoke-Zigup @('use', $version)
    Assert-True ($result.Code -eq 0) 'select managed test toolchain'

    $unrelatedProcess = Start-Process -FilePath $systemPing -ArgumentList @('-t', '127.0.0.1') -PassThru -WindowStyle Hidden
    $targetProcess = Start-Process -FilePath $testZig -ArgumentList @('-t', '127.0.0.1') -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    Assert-True (-not $targetProcess.HasExited) 'target toolchain process is running'
    Assert-True (-not $unrelatedProcess.HasExited) 'unrelated process is running'

    $result = Invoke-Zigup @('remove', $version)
    Assert-True ($result.Code -ne 0) 'normal remove refuses an in-use toolchain'
    Assert-True ($result.Output.Contains('[Incomplete]')) "refused removal is explicitly incomplete: $($result.Output)"
    Assert-True ($result.Output.Contains('ToolchainInUse')) 'refused removal reports lock reason'
    $targetProcess.Refresh()
    Assert-True (-not $targetProcess.HasExited) 'normal remove does not stop the target process'
    Assert-True ([IO.File]::Exists($testZig)) 'normal remove preserves the executable'
    Assert-True ([IO.File]::Exists($sentinel)) 'normal remove preserves other toolchain files'
    Assert-True ([IO.File]::Exists((Join-Path $testRoot "versions\$version.path"))) 'normal remove preserves registration'
    Assert-True ([IO.File]::Exists((Join-Path $testRoot "versions\$version.incomplete"))) 'normal remove persists incomplete marker'
    Assert-True ([IO.File]::Exists((Join-Path $testRoot 'current'))) 'normal remove preserves active selection'
    Assert-True ([IO.File]::Exists((Join-Path $testRoot 'bin\zig.cmd'))) 'normal remove preserves active shim'
    $list = Invoke-Zigup @('list')
    Assert-True ($list.Code -eq 0 -and $list.Output.Contains("$version [Incomplete]")) 'list displays incomplete version'

    $result = Invoke-Zigup @('remove', '-force', $version)
    Assert-True ($result.Code -eq 0) "force remove succeeds: $($result.Output)"
    Assert-True ($result.Output.Contains('force-stopped')) 'force remove reports terminated processes'
    $targetProcess.Refresh()
    $unrelatedProcess.Refresh()
    Assert-True ($targetProcess.HasExited) 'force remove stops the target process'
    Assert-True (-not $unrelatedProcess.HasExited) 'force remove preserves unrelated same-name process'
    Assert-True (-not [IO.Directory]::Exists($toolchain)) 'force remove deletes managed toolchain'
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot "versions\$version.path"))) 'force remove deletes registration'
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot "versions\$version.incomplete"))) 'force remove clears incomplete marker'
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot 'current'))) 'force remove clears active selection'
    Assert-True (-not [IO.File]::Exists((Join-Path $testRoot 'bin\zig.cmd'))) 'force remove clears active shim'

    # A process with a different image locks a library file. Probe every file
    # before deletion and use Restart Manager to release the actual owner.
    $version = '2.0.0-file-lock'
    $toolchain = Join-Path $testRoot "toolchains\$version"
    [IO.Directory]::CreateDirectory((Join-Path $toolchain 'lib')) | Out-Null
    $testZig = Join-Path $toolchain 'zig.exe'
    [IO.File]::Copy($systemPing, $testZig, $false)
    $lockedFile = Join-Path $toolchain 'lib\std.zig'
    [IO.File]::WriteAllText($lockedFile, 'locked library')
    Assert-True ((Invoke-Zigup @('add', $version, $testZig)).Code -eq 0) 'register library-lock fixture'
    $ready = Join-Path $testRoot 'owner-ready'
    $fixture = Join-Path $PSScriptRoot 'windows_lock_fixture.ps1'
    $fileOwner = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$fixture`"", '-LockPath', "`"$lockedFile`"", '-ReadyPath', "`"$ready`"") -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True ([IO.File]::Exists($ready)) 'library-lock owner is ready'
    $result = Invoke-Zigup @('remove', $version)
    Assert-True ($result.Code -ne 0 -and $result.Output.Contains('ToolchainInUse')) 'library lock stops ordinary removal'
    Assert-True ([IO.File]::Exists($testZig) -and [IO.File]::Exists($lockedFile)) 'library lock check happens before deleting executable'
    $result = Invoke-Zigup @('remove', '-force', $version)
    Assert-True ($result.Code -eq 0) "force releases library lock: $($result.Output)"
    $fileOwner.Refresh()
    Assert-True ($fileOwner.HasExited -and -not [IO.Directory]::Exists($toolchain)) 'force terminates file owner and completes deletion'
    $unrelatedProcess.Refresh()
    Assert-True (-not $unrelatedProcess.HasExited) 'file-lock force preserves unrelated process'

    # Failure after the managed files were deleted must retain the registration
    # and marker, report failure, and allow retry even though zig.exe is gone.
    $version = '3.0.0-late-failure'
    $toolchain = Join-Path $testRoot "toolchains\$version"
    [IO.Directory]::CreateDirectory($toolchain) | Out-Null
    $testZig = Join-Path $toolchain 'zig.exe'
    [IO.File]::Copy($systemPing, $testZig, $false)
    Assert-True ((Invoke-Zigup @('add', $version, $testZig)).Code -eq 0) 'register late failure fixture'
    $registration = Join-Path $testRoot "versions\$version.path"
    $heldFile = [IO.File]::Open($registration, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $result = Invoke-Zigup @('remove', $version)
    Assert-True ($result.Code -ne 0 -and $result.Output.Contains('[Incomplete]')) 'late failure is never reported as success'
    Assert-True (-not [IO.Directory]::Exists($toolchain)) 'late failure occurs after toolchain deletion'
    Assert-True ([IO.File]::Exists($registration)) 'late failure retains registration'
    Assert-True ((Invoke-Zigup @('list')).Output.Contains("$version [Incomplete]")) 'late failure remains visible in list'
    $heldFile.Dispose(); $heldFile = $null
    Assert-True ((Invoke-Zigup @('remove', $version)).Code -eq 0) 'late failure retry succeeds without executable'
    Assert-True (-not [IO.File]::Exists($registration)) 'retry removes registration'

    # Store/update mutexes are nonblocking, including in force mode.
    foreach ($lockName in @('store.lock', 'update.lock')) {
        $heldFile = [IO.File]::Open((Join-Path $testRoot $lockName), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        $heldFile.Lock(0, 1)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-Zigup @('remove', '-force', 'no-such-version')
        $watch.Stop()
        Assert-True ($result.Code -ne 0 -and $result.Output.Contains('RemovalAlreadyRunning')) "$lockName conflict is reported"
        Assert-True ($watch.Elapsed.TotalSeconds -lt 5) "$lockName conflict returns immediately"
        $heldFile.Dispose(); $heldFile = $null
    }

    # Run sweep through the CLI against a separate store and exercise numeric
    # ordering, active selections, cache cleanup, and a retry after a lock.
    $sweepHome = Join-Path $testRoot 'sweep'
    $env:ZIGUP_HOME = $sweepHome
    $stable = '0.10.0'
    $dev = '0.11.0-dev.10+abc'
    $oldStable = '0.9.0'
    $oldDev = '0.11.0-dev.9+def'
    $olderDev = '0.10.0-dev.100+abc'
    $downloads = Join-Path $sweepHome 'downloads'
    [IO.Directory]::CreateDirectory($downloads) | Out-Null

    foreach ($label in @($oldStable, $stable, $oldDev, $dev, $olderDev)) {
        $dir = Join-Path $sweepHome "toolchains\$label"
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $exe = Join-Path $dir 'zig.exe'
        [IO.File]::Copy($systemPing, $exe, $false)
        Assert-True ((Invoke-Zigup @('add', $label, $exe)).Code -eq 0) "register $label for sweep"
    }
    Assert-True ((Invoke-Zigup @('use', $oldStable)).Code -eq 0) 'select older stable for sweep'
    [IO.File]::WriteAllText((Join-Path $sweepHome 'current-dev'), $oldDev.ToUpperInvariant())
    $external = Join-Path $testRoot 'external-zig.exe'
    [IO.File]::Copy($systemPing, $external, $false)
    foreach ($label in @('0.8.0', 'local-build')) {
        Assert-True ((Invoke-Zigup @('add', $label, $external)).Code -eq 0) "register external $label"
    }
    $oldArchives = @("zig-stable-$oldStable.zip", "zig-dev-$oldDev.zip", 'zig-stable-0.7.0.zip')
    $keepArchives = @("zig-stable-$stable.zip", "zig-dev-$dev.zip", 'zig-stable-0.11.0.zip', 'unrelated.zip')
    foreach ($name in ($oldArchives + $keepArchives)) {
        [IO.File]::WriteAllText((Join-Path $downloads $name), 'fixture')
    }

    $heldFile = [IO.File]::Open((Join-Path $sweepHome 'update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $heldFile.Lock(0, 1)
    $result = Invoke-Zigup @('sweep')
    Assert-True ($result.Code -ne 0 -and $result.Output.Contains('RemovalAlreadyRunning')) "sweep respects update lock: $($result.Output)"
    Assert-True ([IO.File]::Exists((Join-Path $downloads $oldArchives[0]))) 'refused sweep leaves obsolete archive intact'
    $heldFile.Dispose(); $heldFile = $null

    $lockedExe = Join-Path $sweepHome "toolchains\$oldDev\zig.exe"
    $heldFile = [IO.File]::Open($lockedExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $result = Invoke-Zigup @('sweep')
    Assert-True ($result.Code -ne 0 -and $result.Output.Contains('ToolchainInUse')) "sweep reports locked old dev: $($result.Output)"
    Assert-True ([IO.File]::Exists($lockedExe)) 'sweep leaves the locked executable intact'
    Assert-True ((Invoke-Zigup @('list')).Output.Contains("$oldDev [Incomplete]")) 'sweep marks locked removal for retry'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $sweepHome "toolchains\$oldStable"))) 'sweep removes older stable despite locked dev'
    $heldFile.Dispose(); $heldFile = $null

    $result = Invoke-Zigup @('sweep')
    Assert-True ($result.Code -eq 0) "sweep retries successfully: $($result.Output)"
    foreach ($label in @($oldDev, $olderDev, '0.8.0')) {
        Assert-True (-not [IO.File]::Exists((Join-Path $sweepHome "versions\$label.path"))) "sweep unregisters $label"
    }
    foreach ($label in @($oldDev, $olderDev)) {
        Assert-True (-not [IO.Directory]::Exists((Join-Path $sweepHome "toolchains\$label"))) "sweep deletes managed $label"
    }
    Assert-True ([IO.File]::Exists($external)) 'sweep preserves the external executable'
    Assert-True ([IO.File]::Exists((Join-Path $sweepHome 'versions\local-build.path'))) 'sweep preserves custom registrations'
    foreach ($name in $oldArchives) {
        Assert-True (-not [IO.File]::Exists((Join-Path $downloads $name))) "sweep deletes cached $name"
    }
    foreach ($name in $keepArchives) {
        Assert-True ([IO.File]::Exists((Join-Path $downloads $name))) "sweep preserves cached $name"
    }
    foreach ($channel in @(@('current', 'zig.cmd', $stable), @('current-dev', 'zig-dev.cmd', $dev))) {
        $exe = Join-Path $sweepHome "toolchains\$($channel[2])\zig.exe"
        Assert-True ([IO.File]::Exists($exe)) "sweep preserves latest $($channel[2])"
        Assert-True ([IO.File]::ReadAllText((Join-Path $sweepHome $channel[0])) -eq $channel[2]) "sweep updates $($channel[0])"
        Assert-True ([IO.File]::ReadAllText((Join-Path $sweepHome "bin\$($channel[1])")).Contains($exe)) "sweep updates $($channel[1])"
    }
    $result = Invoke-Zigup @('sweep')
    Assert-True ($result.Code -eq 0 -and $result.Output.Contains('no obsolete')) 'sweep is idempotent'

    Assert-True ((Invoke-Zigup @('add', '0.20.0', $external)).Code -eq 0) 'register a newer stable for validation'
    [IO.File]::Delete($external)
    $result = Invoke-Zigup @('sweep')
    Assert-True ($result.Code -ne 0) 'sweep refuses to replace a working Zig with a missing executable'
    Assert-True ([IO.File]::Exists((Join-Path $sweepHome "toolchains\$stable\zig.exe"))) 'sweep preserves working stable when replacement is missing'
}
finally {
    if ($null -ne $heldFile) { $heldFile.Dispose() }
    foreach ($process in @($targetProcess, $unrelatedProcess, $fileOwner)) {
        if ($null -eq $process) { continue }
        try {
            $process.Refresh()
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        }
        catch {}
        $process.Dispose()
    }
    if ($hadHome) { $env:ZIGUP_HOME = $oldHome }
    else { Remove-Item Env:ZIGUP_HOME -ErrorAction SilentlyContinue }

    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notlike 'zigup-remove-test-*') {
        throw 'test cleanup target failed validation'
    }
    if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}

Write-Host "Windows remove tests passed: $script:Assertions assertions"
