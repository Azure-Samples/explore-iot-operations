#requires -Version 7.4
<#
.SYNOPSIS
Runs Rust connector validation (cargo fmt --check, check, clippy, test) inside an ephemeral Docker
image so hosts without a Rust/OpenSSL toolchain can complete every build/test gate.

.DESCRIPTION
The connector project is streamed to `docker build` as an in-memory tar context together with an
in-memory validation Dockerfile, so nothing is written into the connector workspace (except
Cargo.lock in `lock` mode). The image mirrors the connector Dockerfile build stage: the same base
image, openssl-devel/pkgconfig, and the rustup toolchain pinned by ARG RUST_VERSION, plus rustfmt
and clippy. Each cargo command runs in its own `docker run --rm --network none` container with no
bind mounts, volumes, or `docker cp`. Stdout carries exactly one compact JSON result line; progress
and tool output go to stderr. The ephemeral image and containers are always removed.

.PARAMETER ConnectorProjectPath
The inner connector project directory (`<workspace>/<name>`) containing Cargo.toml. It must be
inside the active Git repository.

.PARAMETER Commands
Ordered validation commands: fmt-check, check, clippy, test (default: all four). Values may be a
single comma-separated string. `lock` resolves Cargo.lock MSRV-compatibly inside the container,
writes it to the project, and must be used alone.

.PARAMETER RustVersion
Toolchain to install with rustup. Defaults to ARG RUST_VERSION in the project's Dockerfile.release.

.PARAMETER CommandTimeoutSeconds
Upper bound for each cargo container run.

.PARAMETER BuildTimeoutSeconds
Upper bound for building the validation image.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConnectorProjectPath,
    [string[]]$Commands = @('fmt-check', 'check', 'clippy', 'test'),
    [ValidatePattern('^[0-9]+\.[0-9]+(?:\.[0-9]+)?$')][string]$RustVersion,
    [ValidateRange(30, 7200)][int]$CommandTimeoutSeconds = 1800,
    [ValidateRange(60, 7200)][int]$BuildTimeoutSeconds = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AkriRustToolchain.ps1')

# Docker CLI used for every container operation. Tests substitute this only in a private copy.
$dockerCommand = 'docker'
$imageLabel = 'org.akri.rust-validation=1'
$validationDockerfileName = '.akri-rust-validation.Dockerfile'
$cargoCommands = [ordered]@{
    'fmt-check' = @('cargo', 'fmt', '--all', '--', '--check')
    'check' = @('cargo', 'check', '--locked', '--offline', '--all-targets')
    'clippy' = @('cargo', 'clippy', '--locked', '--offline', '--all-targets', '--', '-D', 'warnings')
    'test' = @('cargo', 'test', '--locked', '--offline')
    'lock' = @('sh', '-c', 'cargo generate-lockfile && cat Cargo.lock')
}

function Write-Log {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Resolve-PhysicalDirectory {
    <# Resolves every existing path component through symbolic links and junctions. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $resolved = $root
    foreach ($segment in $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $candidate = Join-Path $resolved $segment
        if (-not (Test-Path -LiteralPath $candidate)) { throw "Path '$Path' does not exist." }
        $target = (Get-Item -LiteralPath $candidate -Force).ResolveLinkTarget($true)
        $resolved = if ($null -ne $target) { $target.FullName } else { $candidate }
    }
    return [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/')
}

function Test-WithinRoot {
    param([string]$Path, [string]$Root)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Path.Equals($Root.TrimEnd('\', '/'), $comparison) -or $Path.StartsWith($prefix, $comparison)
}

function Get-RequestedCommands {
    $requested = @($Commands | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
    if ($requested.Count -eq 0) { throw 'Commands must name at least one validation command.' }
    foreach ($name in $requested) {
        if (-not $cargoCommands.Contains($name)) {
            throw "Unsupported command '$name'. Use fmt-check, check, clippy, test, or lock."
        }
    }
    if (@($requested | Select-Object -Unique).Count -ne $requested.Count) { throw 'Commands must be unique.' }
    if ('lock' -in $requested -and $requested.Count -ne 1) { throw "The 'lock' command must run alone." }
    return , $requested
}

function ConvertTo-IgnoreRegex {
    <# Converts one .dockerignore pattern into an anchored regular expression. #>
    param([string]$Pattern)
    $builder = [Text.StringBuilder]::new('^')
    for ($index = 0; $index -lt $Pattern.Length; $index++) {
        $character = $Pattern[$index]
        if ($character -eq '*') {
            if ($index + 1 -lt $Pattern.Length -and $Pattern[$index + 1] -eq '*') {
                $index++
                if ($index + 1 -lt $Pattern.Length -and $Pattern[$index + 1] -eq '/') {
                    $index++
                    $null = $builder.Append('(?:.*/)?')
                } else { $null = $builder.Append('.*') }
            } else { $null = $builder.Append('[^/]*') }
        } elseif ($character -eq '?') {
            $null = $builder.Append('[^/]')
        } else {
            $null = $builder.Append([regex]::Escape([string]$character))
        }
    }
    return [regex]::new($builder.Append('$').ToString(), [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-IgnoreRules {
    param([string]$ProjectPath)
    $rules = [Collections.Generic.List[object]]::new()
    $file = Join-Path $ProjectPath '.dockerignore'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($file)) {
            $pattern = $line.Trim()
            if (-not $pattern -or $pattern.StartsWith('#')) { continue }
            $negate = $pattern.StartsWith('!')
            if ($negate) { $pattern = $pattern.Substring(1).Trim() }
            $pattern = $pattern.Replace('\', '/') -replace '^(?:\./|/)+', '' -replace '/+$', ''
            if (-not $pattern) { continue }
            $rules.Add([pscustomobject]@{ Negate = $negate; Regex = ConvertTo-IgnoreRegex $pattern })
        }
    }
    return , $rules
}

function Test-Ignored {
    <# Applies Docker semantics: the last matching pattern wins and a match on a parent covers children. #>
    param([string]$RelativePath, [object]$Rules)
    $segments = $RelativePath.Split('/')
    if ($segments[0] -in @('target', '.git') -or $RelativePath -in @('.dockerignore', $validationDockerfileName)) { return $true }
    $ignored = $false
    foreach ($rule in $Rules) {
        for ($length = $segments.Count; $length -ge 1; $length--) {
            if ($rule.Regex.IsMatch(($segments[0..($length - 1)] -join '/'))) {
                $ignored = -not $rule.Negate
                break
            }
        }
    }
    return $ignored
}

function New-ValidationDockerfile {
    param([string]$BaseImage)
    @"
FROM $BaseImage
WORKDIR /build
ARG RUST_VERSION
RUN tdnf update -y && tdnf install -y openssl-devel pkgconfig curl ca-certificates && tdnf clean all && \
    (tdnf remove -y rust || true) && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain `${RUST_VERSION} --profile minimal --component rustfmt --component clippy
ENV PATH="/root/.cargo/bin:`${PATH}" CARGO_TERM_COLOR=never CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback
COPY . .
ARG AKRI_FETCH=1
RUN if [ "`$AKRI_FETCH" = "1" ]; then cargo fetch --locked; fi
"@ -replace "`r`n", "`n"
}

function New-BuildContext {
    <# Builds the tar build context in memory, failing closed on links and honoring .dockerignore. #>
    param([string]$ProjectPath, [string]$Dockerfile)
    $rules = Get-IgnoreRules $ProjectPath
    $memory = [IO.MemoryStream]::new()
    # GNU format: Docker's stdin archive detection rejects .NET PAX extended headers.
    $writer = [Formats.Tar.TarWriter]::new($memory, [Formats.Tar.TarEntryFormat]::Gnu, $true)
    try {
        $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $pending.Push([IO.DirectoryInfo]::new($ProjectPath))
        $anyNegation = @($rules | Where-Object Negate).Count -gt 0
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($item in $directory.EnumerateFileSystemInfos() | Sort-Object Name) {
                $relative = [IO.Path]::GetRelativePath($ProjectPath, $item.FullName).Replace('\', '/')
                $ignored = Test-Ignored $relative $rules
                $isDirectory = $item -is [IO.DirectoryInfo]
                if ($ignored -and -not ($isDirectory -and $anyNegation -and $relative.Split('/')[0] -notin @('target', '.git'))) { continue }
                if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or $item.LinkTarget) {
                    throw "Refusing to send linked path '$relative' in the validation build context."
                }
                if ($isDirectory) {
                    if (-not $ignored) { $writer.WriteEntry($item.FullName, "$relative/") }
                    $pending.Push($item)
                } elseif (-not $ignored) {
                    $writer.WriteEntry($item.FullName, $relative)
                }
            }
        }
        $entry = [Formats.Tar.GnuTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile, $validationDockerfileName)
        $entry.Mode = [IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead'
        $entry.DataStream = [IO.MemoryStream]::new([Text.UTF8Encoding]::new($false).GetBytes($Dockerfile))
        $writer.WriteEntry($entry)
    } finally {
        $writer.Dispose()
    }
    $memory.Position = 0
    return $memory
}

function Start-DockerProcess {
    param([string[]]$Arguments, [bool]$RedirectInput)
    $start = if ($dockerCommand.EndsWith('.ps1')) {
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $dockerCommand)) { $info.ArgumentList.Add($argument) }
        $info
    } else {
        [Diagnostics.ProcessStartInfo]::new($dockerCommand)
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $RedirectInput
    $start.Environment['BUILDKIT_PROGRESS'] = 'plain'
    $start.Environment['DOCKER_CLI_HINTS'] = 'false'
    try { return [Diagnostics.Process]::Start($start) } catch { throw "Docker CLI '$dockerCommand' could not be started: $($_.Exception.Message)" }
}

function Invoke-Docker {
    <#
    .SYNOPSIS
    Runs one Docker CLI invocation with a bounded timeout and cooperative cancellation.
    .OUTPUTS
    ExitCode (-1 on timeout), TimedOut, Stdout, Stderr, DurationSeconds.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [IO.Stream]$InputStream,
        [string]$ContainerName
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-DockerProcess $Arguments ($null -ne $InputStream)
    $script:activeProcess = $process
    $script:activeContainer = $ContainerName
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $copyTask = if ($InputStream) { $InputStream.CopyToAsync($process.StandardInput.BaseStream) }
    $inputClosed = $null -eq $InputStream
    $timedOut = $false
    try {
        while (-not $process.WaitForExit(200)) {
            if (-not $inputClosed -and $copyTask.IsCompleted) {
                try { $process.StandardInput.Close() } catch { Write-Log "Docker input stream closed early: $($_.Exception.Message)" }
                $inputClosed = $true
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Stop-ActiveDocker
                break
            }
        }
        $process.WaitForExit()
        $null = $stdoutTask.Wait(5000); $null = $stderrTask.Wait(5000)
        $stdout = if ($stdoutTask.IsCompletedSuccessfully) { $stdoutTask.Result } else { '' }
        $stderr = if ($stderrTask.IsCompletedSuccessfully) { $stderrTask.Result } else { '' }
        $script:activeProcess = $null
        $script:activeContainer = $null
        [pscustomobject]@{
            ExitCode = if ($timedOut) { -1 } else { $process.ExitCode }
            TimedOut = $timedOut
            Stdout = $stdout
            Stderr = $stderr
            DurationSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
        }
    } finally {
        # Reached with an active process only on cancellation (Ctrl+C) or an unexpected error.
        if ($script:activeProcess) { Stop-ActiveDocker }
        $process.Dispose()
    }
}

function Stop-ActiveDocker {
    if ($script:activeProcess -and -not $script:activeProcess.HasExited) {
        try { $script:activeProcess.Kill($true) } catch { Write-Log "Could not stop Docker client: $($_.Exception.Message)" }
    }
    if ($script:activeContainer) {
        Invoke-Cleanup @('rm', '-f', $script:activeContainer) | Out-Null
    }
    $script:activeProcess = $null
    $script:activeContainer = $null
}

function Invoke-Cleanup {
    <# Runs a bounded cleanup command synchronously; returns the exit code. #>
    param([string[]]$Arguments)
    $process = Start-DockerProcess $Arguments $false
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); return -1 }
        $process.WaitForExit()
        $null = $stdoutTask.Wait(1000); $null = $stderrTask.Wait(1000)
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Get-OutputTail {
    param([string]$Text, [int]$Lines = 40)
    $all = @(($Text -replace "`r`n", "`n").TrimEnd("`n").Split("`n"))
    $tail = ($all | Select-Object -Last $Lines) -join "`n"
    if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
    return $tail
}

function Write-Result {
    param([System.Collections.IDictionary]$Result)
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Compress -Depth 6))
}

$requestedCommands = Get-RequestedCommands
$lockMode = $requestedCommands[0] -eq 'lock'

if ($ConnectorProjectPath.Split([char[]]@('\', '/')) -contains '..') {
    throw 'ConnectorProjectPath must not contain parent-directory traversal.'
}
$repositoryOutput = @(& git -C $PWD.Path rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $repositoryOutput.Count -ne 1) {
    throw 'Run this script from inside the active Git repository.'
}
$repositoryRoot = Resolve-PhysicalDirectory $repositoryOutput[0]
$candidatePath = if ([IO.Path]::IsPathFullyQualified($ConnectorProjectPath)) { $ConnectorProjectPath } else { Join-Path $PWD.Path $ConnectorProjectPath }
if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
    throw "ConnectorProjectPath '$ConnectorProjectPath' is not an existing directory."
}
$projectPath = Resolve-PhysicalDirectory $candidatePath
if (-not (Test-WithinRoot $projectPath $repositoryRoot)) {
    throw "ConnectorProjectPath must be inside the active Git repository '$repositoryRoot'."
}
if (-not (Test-Path -LiteralPath (Join-Path $projectPath 'Cargo.toml') -PathType Leaf)) {
    throw "ConnectorProjectPath '$ConnectorProjectPath' does not contain Cargo.toml."
}
$relativeProject = [IO.Path]::GetRelativePath($repositoryRoot, $projectPath).Replace('\', '/')

$pin = Test-AkriRustToolchainPin -ProjectPath $projectPath -AllowMissingLock:$lockMode
$dockerfileToolchain = Get-AkriDockerfileRustToolchain (Join-Path $projectPath 'Dockerfile.release')
$pinErrors = @($pin.Errors)
if ($RustVersion) {
    # An explicit toolchain replaces the Dockerfile ARG; the manifest must still match it.
    $explicitMajorMinor = ($RustVersion -split '\.')[0..1] -join '.'
    $pinErrors = @($pinErrors | Where-Object { $_ -notlike 'Dockerfile*' -and $_ -notlike 'Cargo.toml rust-version*' })
    if ($pin.ManifestRustVersion -and $pin.ManifestRustVersion -cne $explicitMajorMinor) {
        $pinErrors += "Cargo.toml rust-version '$($pin.ManifestRustVersion)' must equal RUST_VERSION major.minor '$explicitMajorMinor'."
    }
} elseif ($dockerfileToolchain.Error) {
    throw "RustVersion could not be read from Dockerfile.release: $($dockerfileToolchain.Error)"
} else {
    $RustVersion = $dockerfileToolchain.RustVersion
}
$baseImage = $dockerfileToolchain.BaseImage
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$imageTag = "akri-rust-validation-$runId`:local"
$commandRecords = [Collections.Generic.List[object]]::new()
$validationCommands = [Collections.Generic.List[string]]::new()
$validationToolchain = [Collections.Generic.List[string]]::new()
$result = [ordered]@{
    version = 1
    status = 'failed'
    projectPath = $relativeProject
    rustVersion = $RustVersion
    baseImage = $baseImage
    imageDigest = $null
    toolchainPin = [ordered]@{
        passed = $pinErrors.Count -eq 0
        manifestRustVersion = $pin.ManifestRustVersion
        lockPresent = $pin.LockPresent
        errors = @($pinErrors)
    }
    commands = $commandRecords
    validationCommands = $validationCommands
    validationToolchain = $validationToolchain
    cleanup = [ordered]@{ status = 'not-required' }
}
if ($pinErrors.Count) {
    Write-Log "Rust toolchain pin check failed: $($pinErrors -join ' ')"
    Write-Result $result
    exit 1
}

$script:activeProcess = $null
$script:activeContainer = $null
$outcome = @{ BuildAttempted = $false; ImageBuilt = $false; AllPassed = $false }
try {
  # Child scope so early 'return' still reaches cleanup, the JSON result, and the exit code.
  & {
    $context = New-BuildContext $projectPath (New-ValidationDockerfile $baseImage)
    $outcome.BuildAttempted = $true
    $result.cleanup.status = 'pending'
    Write-Log "Building validation image (Rust $RustVersion on $baseImage)..."
    $build = Invoke-Docker -TimeoutSeconds $BuildTimeoutSeconds -InputStream $context -Arguments @(
        'build', '-f', $validationDockerfileName,
        '--build-arg', "RUST_VERSION=$RustVersion",
        '--build-arg', "AKRI_FETCH=$(if ($lockMode) { '0' } else { '1' })",
        '--label', $imageLabel, '-t', $imageTag, '-')
    $context.Dispose()
    Write-Log $build.Stderr
    $commandRecords.Add([ordered]@{
        name = 'image-build'
        command = "docker build (validation image, rust $RustVersion$(if (-not $lockMode) { ', cargo fetch --locked' }))"
        status = if ($build.TimedOut) { 'timed-out' } elseif ($build.ExitCode -eq 0) { 'passed' } else { 'failed' }
        exitCode = $build.ExitCode
        durationSeconds = $build.DurationSeconds
        outputTail = Get-OutputTail ($build.Stdout + "`n" + $build.Stderr)
    })
    if ($build.ExitCode -ne 0) { return }
    $outcome.ImageBuilt = $true
    $inspect = Invoke-Docker -TimeoutSeconds 120 -Arguments @('image', 'inspect', '--format', '{{.Id}}', $imageTag)
    if ($inspect.ExitCode -ne 0 -or $inspect.Stdout.Trim() -notmatch '^sha256:[a-f0-9]{64}$') {
        Write-Log 'Could not resolve the validation image digest.'
        return
    }
    $imageId = $inspect.Stdout.Trim()
    $result.imageDigest = $imageId

    $index = 0
    $toolchain = Invoke-Docker -TimeoutSeconds 300 -ContainerName "akri-rust-validation-$runId-$index" -Arguments @(
        'run', '--rm', '--network', 'none', '--name', "akri-rust-validation-$runId-$index", '--label', $imageLabel, $imageId,
        'sh', '-c', 'rustc --version && cargo --version && cargo fmt --version && cargo clippy --version')
    if ($toolchain.ExitCode -ne 0) {
        Write-Log "Toolchain evidence failed: $($toolchain.Stderr)"
        return
    }
    foreach ($line in ($toolchain.Stdout -replace "`r", '').Split("`n")) {
        if ($line.Trim()) { $validationToolchain.Add($line.Trim()) }
    }

    $failed = $false
    foreach ($name in $requestedCommands) {
        $index++
        $containerName = "akri-rust-validation-$runId-$index"
        $cargo = $cargoCommands[$name]
        $network = if ($name -eq 'lock') { @() } else { @('--network', 'none') }
        $display = if ($name -eq 'lock') { 'cargo generate-lockfile' } else { $cargo -join ' ' }
        Write-Log "Running: $display"
        $run = Invoke-Docker -TimeoutSeconds $CommandTimeoutSeconds -ContainerName $containerName -Arguments (@(
            'run', '--rm') + $network + @('--name', $containerName, '--label', $imageLabel, $imageId) + $cargo)
        if ($name -ne 'lock') { Write-Log $run.Stdout }
        Write-Log $run.Stderr
        $status = if ($run.TimedOut) { 'timed-out' } elseif ($run.ExitCode -eq 0) { 'passed' } else { 'failed' }
        if ($name -eq 'lock' -and $status -eq 'passed') {
            $lockText = ($run.Stdout -replace "`r`n", "`n")
            if ($lockText -notmatch '(?m)^\[\[package\]\]') {
                $status = 'failed'
            } else {
                [IO.File]::WriteAllText((Join-Path $projectPath 'Cargo.lock'), $lockText.TrimEnd("`n") + "`n", [Text.UTF8Encoding]::new($false))
                $result.toolchainPin.lockPresent = $true
            }
        }
        $commandRecords.Add([ordered]@{
            name = $name
            command = $display
            status = $status
            exitCode = $run.ExitCode
            durationSeconds = $run.DurationSeconds
            outputTail = Get-OutputTail $(if ($name -eq 'lock') { $run.Stderr } else { $run.Stdout + "`n" + $run.Stderr })
        })
        $validationCommands.Add("container $baseImage rust $RustVersion`: $display")
        if ($status -ne 'passed') { $failed = $true; break }
    }
    $outcome.AllPassed = -not $failed
  } | Out-Null
} finally {
    if ($script:activeProcess -or $script:activeContainer) { Stop-ActiveDocker }
    if ($outcome.BuildAttempted) {
        $removeExit = Invoke-Cleanup @('image', 'rm', '-f', $imageTag)
        $result.cleanup.status = if ($removeExit -eq 0 -or -not $outcome.ImageBuilt) { 'removed' } else { 'failed' }
    }
    if ($outcome.AllPassed -and $result.cleanup.status -ne 'failed') { $result.status = 'passed' }
    Write-Result $result
}
exit $(if ($result.status -eq 'passed') { 0 } else { 1 })

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCCYMFbER4cgsQW
# Z7+ItnA1GjQZ04bH9U6YZUEljMsCKaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEILI/hoZgOnG1Di1CQW/a3qVx5NvmEVpndJ52vN+UaSZGMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAbwogi/ZFGHRUpjyT
# DfXV63p+s5Ie5r2ZPLuFoqd1aC6qohtRb7yJb+g6P1M3zCrWPLXkPED+wZr11p20
# y0BKPO0RB8NRxaWKrczw+JM49adX/3o6MErIrFIiRoBguoUa5+g+0mKRfZWQEY90
# MfvfVEdq2UjLWybkgXwiAHLK3nUGyiTD9UNDb5L4+9qn7fpZVMVbinvzUJZazQJe
# qg6MWemDywA9NZPezFrfZ576T7A3d2/TpWDDBOuF2BpXBv68/Cu+O+LMNwiaPTKG
# 0kZLJlxxRb0RvQNBxjb9WBDgwnF0IzgyeB8VX0Evlm13dSygRFXNgjFTRV4gtLFn
# jCG+vKGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBHMTsjciIOvdwx
# HD27ovyPPEY/7jzDoam3wt6ble+k8wIGaqpviHnmGBMyMDI2MTEwNTIxNTkwMS44
# OTVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJaFw0yNzA1MTcxOTQwMDJa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/
# /w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjcrIlOSzpJc4ZeUxEyli6x
# 6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojyvN43SEGWqSfVc3I3BlsY
# T35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4p+9/lyJjD+ULs3YXBhVr
# fZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/nSsmG2P1zv/cv4gSoMBnW
# eQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxODlkfiyHk9Mkk/TrYTjmj
# PCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8OSt835rBzDprrcAhwmgf
# hoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9Nq/GwbfgqKqGmc9xhKuRF
# cjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5CyhNqXYYE/z0pcXdYaNI
# kQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgmA9oSS0EfvFRMWPA/gpSv
# F3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaqGRxrB+2r/7B3X81Tps99
# KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+ArVPlz3w4tqjcTNm1dt3t
# Tua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3QL6aRkXHnJUn8y9iftB/P
# y22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJihdiYpK8cPHFlqZOAiot0+
# GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZlDquskeyuq01DTv91N4q
# M8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3u1Zh3+S3tjQdqN+dyw60
# RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1Pf6def2pqfl3wFc++hkF8
# DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPynGeE5OtvNoK1pkLsm/i8
# F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoDJ4B5mEAS9aT2SKqllLey
# bOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9JsrkhhsKmb11ujqwgJyN
# x92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmjxeqBS4uU5rQeiAnVgpJe
# aVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQDZoaZTCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMxFtkqr7XMXdsRyWU0lSKH
# Z6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7pd4hjAiGA8yMDI2MTEwNTIxNDk1OFoYDzIwMjYxMTA2MjE0OTU4
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDul3iGAgEAMAoCAQACAg9BAgH/MAcC
# AQACAhKGMAoCBQDumMoGAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAMW/
# 0d+fg6DlxIlKzXgAMB7+y06aCtHWm6+YzPO8fvxH4MLuaLGw2pz/+mhZAbmTSJMn
# imx0Pb+MWEsiLXW3RJsydCZtlQtwS/CuGefkh3RxvVdizxmOzGxzU40T1rq8ac9T
# vPF7ACCrurl6DAvSa7uIrLGiZGfp49+T6nL/JjXXgl6rH55Dcr9lyfga+i8C0iNV
# ESEw1a4q+YxWzrnUBKMNqyyj/JsTt9T1nDjRV2hrRqLzxVyP/5k81F2A95Y9Zzlm
# Nn6lhLqXGUPIHl66Hvj1x3kvHea+Ol/QPmffrB0ChGU9QHDsbprihl84OjpUiA9c
# beVKCFoEkJS7vlkgpbsxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBz
# WUmoZn7c6oDrSd3e5wwdSyFl5bHR5pCbGC5djzvxVzCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VBYqLFjUsFnbgqMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAImNbQ+Z0OT
# 9h8AAQAAAiYwIgQg5uCw81wtxxiMbY1GV49E6uCTmn6vBu5gBlaLh+MeLDQwDQYJ
# KoZIhvcNAQELBQAEggIAcwt3KTaGwVyxm5CbieyA87C+BKGIO74MdMw0gezSotsp
# 3LqZ3GXYWLDIvIdYyt7yqI2QMDAc2rGDeT0BT1v5ZcejL59yPG/xpE69W80ft1qQ
# AjiToR7gAZSu0e4SQnh64OubWR8cjBs+rO2uKac6bVRSjKJcBPuDeFVaiODDaRyV
# yKNmdAVLtu21fItFkoaNqWCm67r4EyetWiXYkPVAzd7hC8NnrZcz5wvYHrxJBTGe
# 6mL405jGnK9TP6ts22NxTdtE0cp24vd8L06tGMFx7NGyJwXwjxYYx7dlZRbVpULJ
# S7DyxiE/MiM2pQNPfgQjv2GT/UvH/F3GsDvKa0sApexeqb+U70AgdPPlruFzV17B
# BXYY9qAb6oWDMMTwdo3DXbctmRohVpDNyu1n4sTpF8A7bXw5DHoAMWwBG7NMrD9L
# 3Cxhft4aBSHuMmmuoYyepEdgy18fgvGLR+UtjkyEIWf54Ys9C6QRdJejmpCqDNBa
# PBuLntl6WS7wVyrW/ax698FxTLGVg5N67pHKP3HN1U6+6wxDEtZyHnI36lraBJ0V
# OmKwv24UfnYkqqptIyIXCPfsFxkeLboq2hTrHMH8uM1vnIwnY0FMB/cPeH63/PcM
# TPNAnKy3YEO5Ap1+Abu6VZrNpbP1Rj0ViI3EcemdI3peWzqlJtuLePomNAPEAD8=
# SIG # End signature block
