<#
.SYNOPSIS
    Deploy edge modules to Azure IoT Operations cluster via kubectl through Azure Arc proxy

.DESCRIPTION
    This script deploys edge modules (edgemqttsim, hello-flask, sputnik, demohistorian)
    to the Kubernetes cluster using kubectl through Azure Arc proxy. Runs remotely from Windows
    to edge device on different network.
    
    PREREQUISITES:
    - Cluster must be Arc-connected (run arc_enable.ps1 + enable_custom_locations.sh on edge first)
    - Azure IoT Operations must be deployed (run External-Configurator.ps1 first)
    - Docker Desktop running on Windows (for building containers, unless -SkipBuild is used)
    - Azure CLI with connectedk8s extension
    
.PARAMETER ConfigPath
    Path to aio_config.json. Searches in config/, edge_configs/, or current directory.

.PARAMETER ModuleName
    Specific module to deploy. If not specified, deploys all modules marked true in config.

.PARAMETER Force
    Force redeployment even if module is already running

.PARAMETER SkipBuild
    Skip container build - assumes images already exist in registry

.PARAMETER ImageTag
    Tag for container images (default: latest)

.EXAMPLE
    .\Deploy-EdgeModules.ps1

.EXAMPLE
    .\Deploy-EdgeModules.ps1 -ModuleName edgemqttsim

.EXAMPLE
    .\Deploy-EdgeModules.ps1 -ModuleName hello-flask -Force

.EXAMPLE
    .\Deploy-EdgeModules.ps1 -SkipBuild
    
.NOTES
    Author: Azure IoT Operations Team
    Date: February 2026
    Version: 2.1.0 - Updated for separation of concerns architecture
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("edgemqttsim", "hello-flask", "sputnik", "demohistorian")]
    [string]$ModuleName,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipBuild,
    
    [Parameter(Mandatory=$false)]
    [string]$ImageTag = "latest"
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script variables
$script:ScriptDir = $PSScriptRoot
$script:RepoRoot = Split-Path $script:ScriptDir
$script:ModulesDir = Join-Path $script:RepoRoot "modules"
$script:ConfigDir = Join-Path $script:RepoRoot "config"
$script:LogFile = Join-Path $script:ScriptDir "deploy_edge_modules_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:StartTime = Get-Date
$script:ProxyJob = $null      # Legacy - kept for cleanup safety
$script:ProxyProcess = $null  # Current - background process for Arc proxy
$script:ContainerRegistry = $null  # Container registry from config
$script:ProxyStarted = $false  # Tracks whether Arc proxy was successfully started

#region Logging Functions

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] ${Level}: $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
        default   { Write-Host $logMessage }
    }
    
    # Note: Transcript already captures all output, no need for Add-Content
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}

function Write-WarnLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "WARNING"
}

function Write-Success {
    param([string]$Message)
    Write-Log -Message $Message -Level "SUCCESS"
}

function Write-InfoLog {
    param([string]$Message)
    Write-Log -Message $Message -Level "INFO"
}

#endregion

#region Configuration Functions

function Find-ConfigFile {
    Write-InfoLog "Searching for aio_config.json..."
    
    $searchPaths = @(
        $ConfigPath,
        (Join-Path $script:ConfigDir "aio_config.json"),
        (Join-Path $script:ScriptDir "edge_configs\aio_config.json"),
        (Join-Path $script:ScriptDir "aio_config.json")
    )
    
    foreach ($path in $searchPaths) {
        if ($path -and (Test-Path $path)) {
            Write-InfoLog "Checking: $path"
            Write-Success "Found configuration at: $path"
            return $path
        }
    }
    
    throw "Configuration file aio_config.json not found in any search location"
}

function Find-ClusterInfoFile {
    Write-InfoLog "Searching for cluster_info.json..."
    
    $searchPaths = @(
        (Join-Path $script:ConfigDir "cluster_info.json"),
        (Join-Path $script:ScriptDir "edge_configs\cluster_info.json"),
        (Join-Path $script:ScriptDir "cluster_info.json")
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            Write-InfoLog "Checking: $path"
            Write-Success "Found cluster info at: $path"
            return $path
        }
    }
    
    throw "Cluster info file cluster_info.json not found. Run linux_installer.sh on edge device first."
}

function Load-ClusterInfo {
    param([string]$ClusterInfoPath)
    
    Write-InfoLog "Loading cluster information from: $ClusterInfoPath"
    
    $clusterInfo = Get-Content $ClusterInfoPath -Raw | ConvertFrom-Json
    
    Write-Host "`nCluster Information:"
    Write-Host "  Cluster Name: $($clusterInfo.cluster_name)"
    Write-Host "  Node Name: $($clusterInfo.node_name)"
    Write-Host "  Kubernetes Version: $($clusterInfo.kubernetes_version)"
    Write-Host ""
    
    return $clusterInfo
}

function Load-Configuration {
    param([string]$ConfigFilePath)
    
    Write-InfoLog "Loading configuration from: $ConfigFilePath"
    
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    
    # Check if modules section exists, if not create default
    if (-not $config.PSObject.Properties['modules']) {
        Write-WarnLog "No modules section found in configuration, creating default"
        $modulesConfig = [PSCustomObject]@{
            edgemqttsim = $false
            "hello-flask" = $false
            sputnik = $false
            "wasm-quality-filter-python" = $false
        }
        $config | Add-Member -NotePropertyName "modules" -NotePropertyValue $modulesConfig -Force
    }
    
    # Check for container registry setting
    if ($config.azure.PSObject.Properties['container_registry'] -and $config.azure.container_registry) {
        $script:ContainerRegistry = $config.azure.container_registry
        Write-InfoLog "Container registry: $script:ContainerRegistry"
    } else {
        $script:ContainerRegistry = $null
        Write-WarnLog "No container_registry specified in config. Deployment files must have valid image names."
    }
    
    Write-Host "`nModules Configuration:"
    $moduleProperties = @($config.modules.PSObject.Properties)
    if ($moduleProperties.Count -eq 0) {
        Write-Host "  (No modules configured)" -ForegroundColor Gray
    } else {
        foreach ($module in $moduleProperties) {
            $status = if ($module.Value) { "ENABLED" } else { "disabled" }
            $color = if ($module.Value) { "Green" } else { "Gray" }
            Write-Host "  $($module.Name): " -NoNewline
            Write-Host $status -ForegroundColor $color
        }
    }
    Write-Host ""
    
    return $config
}

#endregion

#region Validation Functions

function Test-DockerDesktop {
    Write-InfoLog "Checking Docker Desktop status..."
    
    # Check if Docker is installed and responding
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>&1
        $dockerExitCode = $LASTEXITCODE
        # Also treat empty version string as a failure (exit 0 but server unreachable)
        $dockerVersionStr = "$dockerVersion".Trim()
        
        if ($dockerExitCode -ne 0 -or [string]::IsNullOrEmpty($dockerVersionStr) -or $dockerVersionStr -match "error during connect|cannot find the file|dockerDesktopLinuxEngine") {
            $ErrorActionPreference = $previousErrorPref
            
            # Check for ARM64-specific WSL2 mount error
            $dockerOutput = docker version 2>&1 | Out-String
            if ($dockerOutput -match "WSL_E_WSL_MOUNT_NOT_SUPPORTED|--mount on ARM64 requires Windows version|error during connect|The system cannot find the file") {
                Write-ErrorLog "Docker Desktop WSL2 error detected"
                
                # Detect ARM64 architecture
                $isARM64 = $env:PROCESSOR_ARCHITECTURE -eq "ARM64"
                
                if ($isARM64) {
                    Write-Host ""
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host "ARM64 WINDOWS: WSL2 VERSION INCOMPATIBILITY DETECTED" -ForegroundColor Red
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host "Docker Desktop requires Windows build 27653+ on ARM64 devices." -ForegroundColor Yellow
                    Write-Host ""
                    
                    # Check current Windows version
                    $osBuild = [System.Environment]::OSVersion.Version.Build
                    Write-Host "Current Information:" -ForegroundColor Cyan
                    Write-Host "  Architecture: ARM64"
                    Write-Host "  Windows Build: $osBuild"
                    Write-Host "  Required Build: 27653 or newer"
                    Write-Host ""
                    
                    if ($osBuild -lt 27653) {
                        Write-Host "IMMEDIATE ACTIONS:" -ForegroundColor Cyan
                        Write-Host "  1. Try WSL reset: wsl --shutdown" -ForegroundColor White
                        Write-Host "  2. Restart Docker Desktop"
                        Write-Host ""
                        Write-Host "PERMANENT FIX - Update Windows:" -ForegroundColor Cyan
                        Write-Host "  1. Open Settings > Windows Update > Windows Insider Program"
                        Write-Host "  2. Join Dev Channel or Canary Channel"
                        Write-Host "  3. Check for updates and install build 27653+"
                        Write-Host "  4. Restart your device"
                        Write-Host ""
                        Write-Host "WORKAROUND - Use this script without building:" -ForegroundColor Cyan
                        Write-Host "  .\ Deploy-EdgeModules.ps1 -ModuleName $ModuleName -SkipBuild" -ForegroundColor Green
                        Write-Host "  (Pre-build containers on another machine and push to registry)"
                    }
                    
                    Write-Host ""
                    Write-Host "ALTERNATIVE: Switch to Hyper-V backend (if available)" -ForegroundColor Cyan
                    Write-Host "  1. Open Docker Desktop Settings"
                    Write-Host "  2. General > Uncheck 'Use WSL 2 based engine'"
                    Write-Host "  3. Apply & Restart"
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host ""
                } else {
                    Write-Host ""
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host "DOCKER DESKTOP CONNECTION ERROR" -ForegroundColor Red
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host "Docker Desktop is not responding. Common causes:" -ForegroundColor Yellow
                    Write-Host "  1. Docker Desktop is not running"
                    Write-Host "  2. WSL2 backend has stopped"
                    Write-Host "  3. Docker service needs restart"
                    Write-Host ""
                    Write-Host "Try these steps:" -ForegroundColor Cyan
                    Write-Host "  1. wsl --shutdown"
                    Write-Host "  2. Restart Docker Desktop"
                    Write-Host "  3. Wait for Docker to fully initialize"
                    Write-Host "  4. Verify: docker ps"
                    Write-Host "============================================================" -ForegroundColor Red
                    Write-Host ""
                }
                
                throw "Docker Desktop is not available. Cannot build containers."
            }
            
            # Generic Docker not running error
            throw "Docker is not running. Start Docker Desktop and try again."
        }
        
        $ErrorActionPreference = $previousErrorPref
        Write-Success "Docker Desktop version: $dockerVersion"
        
        # Test docker connectivity with a simple command
        $dockerPs = docker ps 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-WarnLog "Docker is running but may have connectivity issues"
            Write-InfoLog "Docker ps output: $dockerPs"
        }
        
        return $true
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        throw $_
    }
}

function Test-Prerequisites {
    Write-InfoLog "Checking prerequisites..."
    
    # Check kubectl
    try {
        $kubectlVersion = kubectl version --client 2>$null | Select-Object -First 1
        if ($kubectlVersion) {
            Write-Success "kubectl found: $kubectlVersion"
        } else {
            throw "kubectl not found or not responding"
        }
    }
    catch {
        throw "kubectl is not installed or not in PATH. Install from: https://kubernetes.io/docs/tasks/tools/"
    }
    
    # Check Azure CLI (needed for Arc proxy)
    try {
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        if ($azVersion) {
            Write-Success "Azure CLI version: $azVersion"
        } else {
            throw "Azure CLI not found"
        }
    }
    catch {
        throw "Azure CLI is not installed or not in PATH"
    }
    
    # Check modules directory
    if (-not (Test-Path $script:ModulesDir)) {
        throw "modules directory not found: $script:ModulesDir"
    }
    Write-Success "modules directory found: $script:ModulesDir"
}

function Stop-ArcProxies {
    param([int]$Port = 47011)
    
    $killed = $false
    
    # Kill by stored process reference first (most reliable)
    if ($script:ProxyProcess -and -not $script:ProxyProcess.HasExited) {
        Write-InfoLog "Stopping stored proxy process (PID $($script:ProxyProcess.Id))..."
        $script:ProxyProcess.Kill()
        $script:ProxyProcess = $null
        $killed = $true
    }
    
    # Find any process holding the proxy port via netstat and kill it
    Write-InfoLog "Checking for processes using port $Port..."
    $netstatLines = netstat -ano 2>$null | Select-String ":$Port\s"
    foreach ($line in $netstatLines) {
        if ($line -match '\s+(\d+)\s*$') {
            $procId = [int]$Matches[1]
            if ($procId -gt 0) {
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-InfoLog "Killing PID $procId ($($proc.Name)) holding port $Port"
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                    $killed = $true
                }
            }
        }
    }
    
    if ($killed) {
        Start-Sleep -Seconds 1
        Write-Success "Arc proxy process(es) stopped"
    } else {
        Write-InfoLog "No existing Arc proxy processes found on port $Port"
    }
}

function Start-ArcProxy {
    param(
        [string]$ClusterName,
        [string]$ResourceGroup
    )
    
    # Kill any leftover proxy processes from prior runs before starting a new one
    Stop-ArcProxies
    
    Write-InfoLog "Starting Azure Arc proxy tunnel..."
    Write-InfoLog "Command: az connectedk8s proxy --name $ClusterName --resource-group $ResourceGroup"
    
    # Check if cluster is Arc-enabled
    $arcCluster = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup 2>$null
    if (-not $arcCluster) {
        throw "Cluster $ClusterName is not Arc-enabled. Run External-Configurator.ps1 first."
    }
    Write-Success "Cluster is Arc-enabled"
    
    # Start proxy as a background process, redirecting output to a temp file we can poll
    $proxyLogFile = Join-Path $env:TEMP "arc_proxy_$(Get-Date -Format 'yyyyMMddHHmmss').log"
    # Snapshot kubeconfig modification time BEFORE starting the proxy.
    # We poll for a write AFTER this timestamp to confirm az wrote a fresh CA cert,
    # not just finding the stale 127.0.0.1:47011 entry left from a previous run.
    $kubeconfigPath = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { "$env:USERPROFILE\.kube\config" }
    $kubeconfigMtimeBefore = if (Test-Path $kubeconfigPath) { (Get-Item $kubeconfigPath).LastWriteTime } else { [datetime]::MinValue }
    Write-InfoLog "Kubeconfig path: $kubeconfigPath"
    Write-InfoLog "Kubeconfig mtime before proxy start: $kubeconfigMtimeBefore"
    
    Write-InfoLog "Starting Arc proxy as background process..."
    Write-InfoLog "Proxy output log: $proxyLogFile"
    
    $azExe = (Get-Command az -ErrorAction SilentlyContinue).Source
    if (-not $azExe) { $azExe = "az" }
    
    $proxyProcess = Start-Process -FilePath $azExe `
        -ArgumentList "connectedk8s proxy --name $ClusterName --resource-group $ResourceGroup" `
        -RedirectStandardOutput $proxyLogFile `
        -RedirectStandardError "$proxyLogFile.err" `
        -PassThru -WindowStyle Hidden
    
    # Store for cleanup
    $script:ProxyProcess = $proxyProcess
    
    # Poll netstat for the port entering LISTENING state - more reliable than parsing
    # redirected output (az connectedk8s proxy does not flush to redirected stdout/stderr)
    $proxyPort = 47011
    Write-InfoLog "Waiting for port $proxyPort to enter LISTENING state (timeout: 90s)..."
    $timeout = 90
    $elapsed = 0
    $proxyReady = $false
    
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        
        # Check if process exited unexpectedly
        if ($proxyProcess.HasExited) {
            $errContent = if (Test-Path "$proxyLogFile.err") { Get-Content "$proxyLogFile.err" -Raw } else { "(no stderr)" }
            $outContent = if (Test-Path $proxyLogFile) { Get-Content $proxyLogFile -Raw } else { "(no stdout)" }
            Write-ErrorLog "Proxy process exited unexpectedly (exit code: $($proxyProcess.ExitCode))"
            Write-ErrorLog "Stderr: $errContent"
            Write-ErrorLog "Stdout: $outContent"
            throw "Arc proxy process exited unexpectedly"
        }
        
        # Check if port is LISTENING via netstat
        $netstatOutput = netstat -ano 2>$null
        $listeningLine = $netstatOutput | Select-String ":$proxyPort\s+.*LISTENING"
        Write-InfoLog "[poll ${elapsed}s] checking netstat for *:$proxyPort LISTENING -> $(if ($listeningLine) { "FOUND: $($listeningLine.Line.Trim())" } else { 'not yet' })"
        
        if ($listeningLine) {
            Write-Success "Arc proxy is listening on port $proxyPort"
            $proxyReady = $true
            break
        }
    }
    
    if (-not $proxyReady) {
        $errContent = if (Test-Path "$proxyLogFile.err") { Get-Content "$proxyLogFile.err" -Raw } else { "" }
        Write-ErrorLog "Proxy stderr: $errContent"
        if (-not $proxyProcess.HasExited) { $proxyProcess.Kill() }
        throw "Arc proxy did not start within $timeout seconds"
    }
    
    # Wait for kubeconfig to be written with a FRESH CA cert for this session.
    # We require the file's LastWriteTime to be AFTER the snapshot taken before the proxy
    # started - this distinguishes a fresh write from a stale entry left by a prior run.
    Write-InfoLog "Waiting for kubeconfig to be updated with fresh CA cert (mtime must be after $kubeconfigMtimeBefore)..."
    $kcTimeout = 20
    $kcElapsed = 0
    $kcReady = $false
    while ($kcElapsed -lt $kcTimeout) {
        Start-Sleep -Seconds 1
        $kcElapsed++
        if (Test-Path $kubeconfigPath) {
            $kcMtime = (Get-Item $kubeconfigPath).LastWriteTime
            $kcContent = Get-Content $kubeconfigPath -Raw 2>$null
            $hasAddress = $kcContent -match "127\.0\.0\.1:$proxyPort"
            $isNew = $kcMtime -gt $kubeconfigMtimeBefore
            Write-InfoLog "[kubeconfig poll ${kcElapsed}s] mtime=$kcMtime  isNew=$isNew  hasAddress=$hasAddress"
            if ($hasAddress -and $isNew) {
                Write-Success "Kubeconfig updated with fresh proxy CA cert"
                $kcReady = $true
                break
            }
        } else {
            Write-InfoLog "[kubeconfig poll ${kcElapsed}s] kubeconfig not found yet"
        }
    }
    if (-not $kcReady) {
        Write-WarnLog "Kubeconfig was not updated within $kcTimeout seconds (may have stale CA cert - TLS errors possible)"
    }
    
    Write-Success "Arc proxy established"
    $script:ProxyStarted = $true
}

function Test-ClusterConnection {
    Write-InfoLog "Testing cluster connection via Arc proxy..."
    
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $currentContext = kubectl config current-context 2>$null
        
        # Use api-versions as a lightweight connectivity check - works with minimal RBAC
        $apiOutput = kubectl api-versions 2>&1
        $exitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($exitCode -eq 0) {
            Write-Success "Connected to cluster: $currentContext"
            Write-InfoLog "Connection is through Azure Arc proxy (cross-network)"
            return $true
        }
        
        # A Forbidden response means the API server responded - proxy is working but RBAC is limited
        # This is OK for our purposes (we only need access to the default namespace)
        if ($apiOutput -match "Forbidden|403") {
            Write-WarnLog "Connected to cluster but API discovery is restricted by RBAC (this is OK)"
            Write-WarnLog "Cluster: $currentContext"
            Write-InfoLog "Proceeding - deployment only requires access to the 'default' namespace"
            return $true
        }
        
        # TLS cert error means kubectl reached the proxy but has a stale/mismatched CA.
        # This should have been resolved by the kubeconfig poll above - log and fail clearly.
        if ($apiOutput -match "x509|certificate|tls") {
            Write-ErrorLog "TLS certificate verification failed. The kubeconfig CA cert does not match the proxy."
            Write-ErrorLog "Try deleting the stale kubeconfig context: kubectl config delete-context <arc-context>"
            Write-ErrorLog "kubectl output: $apiOutput"
            return $false
        }
        
        Write-ErrorLog "kubectl api-versions output: $apiOutput"
        return $false
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        # Check if the exception message indicates a Forbidden/RBAC issue (still means we're connected)
        if ($_.Exception.Message -match "Forbidden|403|cannot list|cannot get") {
            Write-WarnLog "Connected to cluster (RBAC restricts some queries, but deployment should proceed)"
            return $true
        }
        Write-ErrorLog "Connection test error: $_"
        return $false
    }
}

function Test-ModuleExists {
    param([string]$Module)
    
    $modulePath = Join-Path $script:ModulesDir $Module
    $deploymentPath = Join-Path $modulePath "deployment.yaml"
    
    if (-not (Test-Path $modulePath)) {
        return @{ Exists = $false; Reason = "Module directory not found" }
    }
    
    if (-not (Test-Path $deploymentPath)) {
        return @{ Exists = $false; Reason = "deployment.yaml not found" }
    }
    
    return @{ Exists = $true; Path = $deploymentPath }
}

function Test-ModuleDeployed {
    param([string]$Module)
    
    Write-InfoLog "Checking if $Module is already deployed..."
    
    # Check for deployment in default namespace (temporarily ignore errors for "not found" cases)
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $deployment = kubectl get deployment -n default -l app=$Module 2>&1
        $exitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($exitCode -eq 0 -and $deployment -notmatch "No resources found") {
            Write-InfoLog "$Module deployment exists"
            return $true
        }
        
        Write-InfoLog "$Module is not currently deployed"
        return $false
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        return $false
    }
}

#endregion

#region Deployment Functions

function Build-AndPushContainer {
    param(
        [string]$Module,
        [string]$Registry,
        [string]$Tag
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Building and Pushing Container" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $modulePath = Join-Path $script:ModulesDir $Module
    
    if (-not (Test-Path (Join-Path $modulePath "Dockerfile"))) {
        throw "Dockerfile not found for module: $Module"
    }
    
    $imageName = "$Registry/${Module}:$Tag"
    Write-InfoLog "Image: $imageName"
    Write-InfoLog "Context: $modulePath"
    
    # Use az acr build for Azure Container Registry (no local Docker required)
    if ($Registry -match '\.azurecr\.io$') {
        $acrName = $Registry -replace '\.azurecr\.io$', ''
        Write-InfoLog "Using az acr build (cloud build - no local Docker needed)"
        Write-InfoLog "ACR: $acrName"
        
        $previousErrorPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        az acr build --registry $acrName --image "${Module}:${Tag}" $modulePath
        $buildExitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($buildExitCode -ne 0) {
            throw "az acr build failed for $Module (exit code: $buildExitCode)"
        }
        
        Write-Success "Container built and pushed via ACR: $imageName"
        return $imageName
    }
    
    # Fallback: local Docker build + push (for non-ACR registries)
    Write-InfoLog "Using local Docker build..."
    
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    $buildOutput = docker build -t $imageName $modulePath 2>&1
    $buildExitCode = $LASTEXITCODE
    
    $ErrorActionPreference = $previousErrorPref
    
    if ($buildExitCode -ne 0) {
        Write-ErrorLog "Docker build failed with exit code: $buildExitCode"
        $buildOutput | ForEach-Object { Write-ErrorLog $_ }
        
        if ($buildOutput -match "dockerDesktopLinuxEngine|The system cannot find the file specified|error during connect|WSL_E_WSL_MOUNT_NOT_SUPPORTED|--mount on ARM64 requires") {
            Write-ErrorLog "Docker Desktop is not available or not running."
            Write-ErrorLog "TIP: If your registry is Azure Container Registry, use an ACR FQDN"
            Write-ErrorLog "     (e.g. myregistry.azurecr.io) to build in the cloud instead."
        }
        
        throw "Failed to build container image"
    }
    
    Write-Success "Container built successfully"
    
    $ErrorActionPreference = "Continue"
    $pushOutput = docker push $imageName 2>&1
    $pushExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorPref
    
    if ($pushExitCode -ne 0) {
        Write-ErrorLog "Docker push failed with exit code: $pushExitCode"
        $pushOutput | ForEach-Object { Write-ErrorLog $_ }
        throw "Failed to push container image"
    }
    
    Write-Success "Container pushed successfully: $imageName"
    return $imageName
}

function Update-DeploymentRegistry {
    param(
        [string]$DeploymentPath,
        [string]$Module
    )
    
    # Read deployment file to check for placeholders
    $deploymentContent = Get-Content $DeploymentPath -Raw
    
    # Check if deployment contains registry placeholders
    $hasPlaceholder = $deploymentContent -match '<YOUR_REGISTRY>'
    
    if ($hasPlaceholder -and -not $script:ContainerRegistry) {
        Write-ErrorLog "Deployment file for '$Module' contains <YOUR_REGISTRY> placeholder but no container_registry is configured"
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "CONFIGURATION ERROR: Container Registry Not Set" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "The deployment file requires a container registry, but none is configured." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To fix this, add the following to your aio_config.json:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host '  "azure": {' -ForegroundColor White
        Write-Host '    "subscription_id": "...",'
        Write-Host '    "resource_group": "...",'
        Write-Host '    "location": "...",'
        Write-Host '    "cluster_name": "...",'
        Write-Host '    "namespace": "...",'
        Write-Host '    "container_registry": "your-dockerhub-username"  // <-- Add this line' -ForegroundColor Green
        Write-Host '  }'
        Write-Host ""
        Write-Host "Examples:" -ForegroundColor Cyan
        Write-Host '  - Docker Hub: "container_registry": "myusername"'
        Write-Host '  - Azure ACR: "container_registry": "myregistry.azurecr.io"'
        Write-Host '  - GitHub: "container_registry": "ghcr.io/myusername"'
        Write-Host ""
        Write-Host "After updating the config file, rebuild and redeploy:" -ForegroundColor Cyan
        Write-Host "  .\Deploy-EdgeModules.ps1 -ModuleName $Module -Force"
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        throw "Container registry not configured in aio_config.json"
    }
    
    if (-not $script:ContainerRegistry) {
        Write-InfoLog "No container registry configured, using deployment.yaml as-is (assumes fully qualified image names)"
        
        # Still update namespace
        $updatedContent = $deploymentContent -replace 'namespace:\s*azure-iot-operations', 'namespace: default'
        
        if ($updatedContent -ne $deploymentContent) {
            $tempPath = Join-Path $env:TEMP "$Module-deployment-$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
            $updatedContent | Set-Content -Path $tempPath -Encoding UTF8
            Write-InfoLog "Updated namespace in temporary deployment file: $tempPath"
            return $tempPath
        }
        
        return $DeploymentPath
    }
    
    Write-InfoLog "Updating deployment YAML with registry and namespace..."
    
    # Replace <YOUR_REGISTRY> placeholder with actual registry
    $updatedContent = $deploymentContent -replace '<YOUR_REGISTRY>', $script:ContainerRegistry
    
    # Update namespace to 'default' instead of 'azure-iot-operations'
    $updatedContent = $updatedContent -replace 'namespace:\s*azure-iot-operations', 'namespace: default'
    
    # Create temp file with updated content
    $tempPath = Join-Path $env:TEMP "$Module-deployment-$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
    $updatedContent | Set-Content -Path $tempPath -Encoding UTF8
    
    Write-InfoLog "Created temporary deployment file: $tempPath"
    Write-InfoLog "Registry: $script:ContainerRegistry"
    Write-InfoLog "Target namespace: default"
    return $tempPath
}

function Ensure-ServiceAccount {
    param(
        [string]$ServiceAccountName = "mqtt-client",
        [string]$Namespace = "default"
    )
    
    Write-InfoLog "Checking if service account '$ServiceAccountName' exists in namespace '$Namespace'..."
    
    # Check if service account exists
    $previousErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    try {
        $saExists = kubectl get serviceaccount $ServiceAccountName -n $Namespace 2>&1
        $exitCode = $LASTEXITCODE
        
        $ErrorActionPreference = $previousErrorPref
        
        if ($exitCode -eq 0 -and $saExists -notmatch "NotFound" -and $saExists -notmatch "No resources found") {
            Write-Success "Service account '$ServiceAccountName' already exists"
            return $true
        }
        
        # Create the service account
        Write-InfoLog "Creating service account '$ServiceAccountName' in namespace '$Namespace'..."
        kubectl create serviceaccount $ServiceAccountName -n $Namespace 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Service account '$ServiceAccountName' created successfully"
            return $true
        } else {
            Write-ErrorLog "Failed to create service account '$ServiceAccountName'"
            return $false
        }
    }
    catch {
        $ErrorActionPreference = $previousErrorPref
        Write-ErrorLog "Error checking/creating service account: $_"
        return $false
    }
}

function Ensure-AcrPullSecret {
    param(
        [string]$Registry,
        [string]$SecretName = "acr-pull-secret",
        [string]$Namespace = "default"
    )

    # Only needed for Azure Container Registry
    if ($Registry -notmatch '\.azurecr\.io$') {
        Write-InfoLog "Registry '$Registry' is not an ACR - skipping pull secret setup"
        return $true
    }

    Write-InfoLog "Ensuring ACR pull secret '$SecretName' in namespace '$Namespace'..."

    # Extract ACR name (everything before .azurecr.io)
    $acrName = $Registry -replace '\.azurecr\.io$', ''

    # Get ACR admin credentials
    Write-InfoLog "Fetching ACR credentials for '$acrName'..."
    $acrCreds = az acr credential show --name $acrName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Failed to get ACR credentials: $acrCreds"
        Write-WarnLog "Make sure admin user is enabled on the ACR:"
        Write-Host "  az acr update --name $acrName --admin-enabled true" -ForegroundColor Cyan
        return $false
    }

    $creds = $acrCreds | ConvertFrom-Json
    $acrUser = $creds.username
    $acrPass = $creds.passwords[0].value

    # Create or update the secret (using --dry-run + apply for idempotency)
    Write-InfoLog "Creating/updating K8s pull secret '$SecretName'..."
    $secretYaml = kubectl create secret docker-registry $SecretName `
        --docker-server=$Registry `
        --docker-username=$acrUser `
        --docker-password=$acrPass `
        --namespace=$Namespace `
        --dry-run=client -o yaml 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Failed to generate pull secret YAML: $secretYaml"
        return $false
    }

    $applyResult = $secretYaml | kubectl apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLog "Failed to apply pull secret: $applyResult"
        return $false
    }

    Write-Success "ACR pull secret '$SecretName' is ready in namespace '$Namespace'"
    return $true
}

function Deploy-Module {
    param(
        [string]$Module,
        [bool]$ForceRedeploy = $false
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deploying Module: $Module" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Check if module exists
    $moduleCheck = Test-ModuleExists -Module $Module
    if (-not $moduleCheck.Exists) {
        Write-ErrorLog "Cannot deploy $Module : $($moduleCheck.Reason)"
        return $false
    }
    
    # Check if already deployed
    $isDeployed = Test-ModuleDeployed -Module $Module
    if ($isDeployed -and -not $ForceRedeploy) {
        Write-WarnLog "$Module is already deployed. Use -Force to redeploy."
        return $true
    }
    
    if ($isDeployed -and $ForceRedeploy) {
        Write-InfoLog "Force redeployment requested, deleting existing deployment..."
        kubectl delete deployment -n default -l app=$Module 2>$null
        Start-Sleep -Seconds 3
    }
    
    # Update deployment file with container registry if configured
    $deploymentPath = Update-DeploymentRegistry -DeploymentPath $moduleCheck.Path -Module $Module
    
    # Deploy using kubectl
    Write-InfoLog "Applying deployment.yaml for $Module..."
    Write-InfoLog "Path: $deploymentPath"
    Write-InfoLog "Using kubectl through Azure Arc proxy (cross-network)"
    
    $deployResult = kubectl apply -f $deploymentPath 2>&1
    $deployExitCode = $LASTEXITCODE
    
    # Clean up temp file if it was created
    if ($deploymentPath -ne $moduleCheck.Path -and (Test-Path $deploymentPath)) {
        Remove-Item $deploymentPath -Force -ErrorAction SilentlyContinue
    }
    
    # Check for InvalidImageName or other image-related errors
    if ($deployResult -match 'InvalidImageName|ErrImagePull|ImagePullBackOff') {
        Write-ErrorLog "Image name or registry configuration error detected"
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "IMAGE CONFIGURATION ERROR" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "Deployment Result:" -ForegroundColor Yellow
        $deployResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "Common causes:" -ForegroundColor Cyan
        Write-Host "  1. Container registry not configured in aio_config.json"
        Write-Host "  2. Image name contains invalid characters or placeholders"
        Write-Host "  3. Image does not exist in the specified registry"
        Write-Host "  4. Registry authentication required but not configured"
        Write-Host ""
        Write-Host "To fix:" -ForegroundColor Cyan
        Write-Host "  1. Add 'container_registry' to azure section in aio_config.json"
        Write-Host "  2. Build and push the container: .\Deploy-EdgeModules.ps1 -ModuleName $Module"
        Write-Host "  3. Verify image exists: docker images | grep $Module"
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        return $false
    }
    
    if ($deployExitCode -eq 0) {
        Write-Success "$Module deployment applied successfully"
        
        # Wait for pod to be ready
        Write-InfoLog "Waiting for pod to be ready (timeout: 60s)..."
        $timeout = 60
        $elapsed = 0
        $ready = $false
        
        # Temporarily allow errors for kubectl commands
        $previousErrorPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        while ($elapsed -lt $timeout) {
            # Check if any pods exist first
            $podCount = kubectl get pods -n default -l app=$Module --no-headers 2>&1 | Measure-Object | Select-Object -ExpandProperty Count
            
            if ($podCount -gt 0) {
                # Now safely check the pod status
                $pod = kubectl get pods -n default -l app=$Module -o jsonpath='{.items[0].status.phase}' 2>&1
                if ($pod -eq "Running") {
                    $ErrorActionPreference = $previousErrorPref
                    Write-Success "$Module pod is running"
                    $ready = $true
                    break
                }
            }
            
            Start-Sleep -Seconds 2
            $elapsed += 2
            Write-Host "." -NoNewline
        }
        Write-Host ""
        
        $ErrorActionPreference = $previousErrorPref
        
        if (-not $ready) {
            Write-WarnLog "$Module pod did not become ready within timeout"
            Write-InfoLog "Check status with: kubectl get pods -n default -l app=$Module"
        }
        
        # Show pod status
        Write-InfoLog "Current pod status:"
        kubectl get pods -n default -l app=$Module
        
        return $true
    } else {
        Write-ErrorLog "Failed to deploy $Module"
        Write-ErrorLog $deployResult
        return $false
    }
}

function Get-ModulesToDeploy {
    param([object]$Config)
    
    if ($ModuleName) {
        Write-InfoLog "Deploying specific module: $ModuleName"
        return @($ModuleName)
    }
    
    $modules = @()
    foreach ($module in $Config.modules.PSObject.Properties) {
        if ($module.Value -eq $true) {
            $modules += $module.Name
        }
    }
    
    if (@($modules).Count -eq 0) {
        Write-WarnLog "No modules enabled in configuration"
    } else {
        Write-InfoLog "Modules to deploy: $($modules -join ', ')"
    }
    
    return $modules
}

function Show-DeploymentStatus {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Deployment Status" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    Write-InfoLog "All deployments in default namespace:"
    kubectl get deployments -n default
    
    Write-Host "`nPods:" -ForegroundColor Cyan
    kubectl get pods -n default
    
    Write-Host "`nServices:" -ForegroundColor Cyan
    kubectl get services -n default
}

function Show-Summary {
    param(
        [int]$Successful,
        [int]$Failed,
        [int]$Total
    )
    
    Write-Host "`n============================================================================" -ForegroundColor Green
    Write-Host "Edge Module Deployment Summary" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    
    Write-Host "`nResults:"
    Write-Host "  Total modules: $Total"
    Write-Host "  Successful: $Successful" -ForegroundColor Green
    if ($Failed -gt 0) {
        Write-Host "  Failed: $Failed" -ForegroundColor Red
    }
    
    $duration = (Get-Date) - $script:StartTime
    Write-Host "`nDeployment completed in $([math]::Round($duration.TotalMinutes, 2)) minutes"
    Write-Host "Log file: $script:LogFile"
    
    Write-Host "`nNext Steps:"
    Write-Host "1. Check pod logs:"
    Write-Host "   kubectl logs -n default -l app=<module-name>"
    Write-Host ""
    Write-Host "2. Monitor module status:"
    Write-Host "   kubectl get pods -n default -w"
    Write-Host ""
    Write-Host "3. View module output (for MQTT modules):"
    Write-Host "   kubectl logs -n default -l app=edgemqttsim -f"
    Write-Host ""
    
    Write-InfoLog "Deployment completed via Azure Arc proxy (Windows -> Linux cross-network)"
    Write-Host ""
}

#endregion

#region Main Execution

function Main {
    try {
        # Start transcript
        Start-Transcript -Path $script:LogFile -Append
        
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Azure IoT Operations - Edge Module Deployment" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "Log file: $script:LogFile"
        Write-Host "Started: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
        Write-Host ""
        Write-Host "NOTE: This script uses kubectl through Azure Arc proxy" -ForegroundColor Yellow
        Write-Host "      Supports cross-network deployment (Windows -> Linux)" -ForegroundColor Yellow
        Write-Host ""
        
        # Check prerequisites
        Test-Prerequisites
        Write-Host ""
        
        # Find and load Azure config
        Write-InfoLog "Loading Azure configuration..."
        $configPath = Find-ConfigFile
        $config = Load-Configuration -ConfigFilePath $configPath
        
        # Extract Azure settings from config file
        $script:ResourceGroup = $config.azure.resource_group
        $script:SubscriptionId = $config.azure.subscription_id
        $script:ClusterName = $config.azure.cluster_name
        
        if (-not $script:ClusterName) {
            throw "cluster_name is not set in aio_config.json (azure.cluster_name)"
        }
        
        Write-Host "`nConfiguration Summary:"
        Write-Host "  Subscription: $script:SubscriptionId"
        Write-Host "  Resource Group: $script:ResourceGroup"
        Write-Host "  Cluster Name: $script:ClusterName"
        Write-Host ""
        
        # Get modules to deploy
        $modulesToDeploy = @(Get-ModulesToDeploy -Config $config)
        
        if ($modulesToDeploy.Count -eq 0) {
            Write-WarnLog "No modules to deploy"
            Write-Host "Update aio_config.json modules section to enable modules"
            exit 0
        }
        
        # Build and push containers BEFORE starting Arc proxy
        if (-not $SkipBuild -and $script:ContainerRegistry) {
            # Only check Docker Desktop for non-ACR registries (ACR builds in the cloud)
            if ($script:ContainerRegistry -notmatch '\.azurecr\.io$') {
                Write-Host ""
                Test-DockerDesktop
                Write-Host ""
            } else {
                Write-InfoLog "ACR registry detected - skipping Docker Desktop check (using az acr build)"
            }
            
            Write-Host "`n========================================" -ForegroundColor Cyan
            Write-Host "Building and Pushing Containers" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            
            foreach ($module in $modulesToDeploy) {
                try {
                    Build-AndPushContainer -Module $module -Registry $script:ContainerRegistry -Tag $ImageTag
                }
                catch {
                    Write-ErrorLog "Failed to build/push $module : $_"
                    throw "Container build failed for $module"
                }
            }
        } elseif (-not $script:ContainerRegistry) {
            Write-WarnLog "No container registry configured - assuming images already exist in registry"
        } else {
            Write-InfoLog "Skipping container build (using existing images)"
        }
        
        # Start Arc proxy for kubectl connectivity
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Establishing Arc Proxy Connection" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Start-ArcProxy -ClusterName $script:ClusterName -ResourceGroup $script:ResourceGroup
        
        # Test connection
        $connected = Test-ClusterConnection
        if (-not $connected) {
            throw "Failed to connect to cluster through Arc proxy"
        }
        Write-Host ""
        
        # Ensure mqtt-client service account exists
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Ensuring Service Account" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        $saResult = Ensure-ServiceAccount -ServiceAccountName "mqtt-client" -Namespace "default"
        if (-not $saResult) {
            Write-WarnLog "Failed to create service account - deployments may fail if they require it"
        }
        Write-Host ""

        # Ensure ACR pull secret exists (required for private Azure Container Registry)
        if ($script:ContainerRegistry) {
            Write-Host "`n========================================" -ForegroundColor Cyan
            Write-Host "Ensuring ACR Pull Secret" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            $pullResult = Ensure-AcrPullSecret -Registry $script:ContainerRegistry -Namespace "default"
            if (-not $pullResult) {
                Write-WarnLog "Failed to create ACR pull secret - image pulls may fail"
            }
            Write-Host ""
        }

        # Deploy each module (containers already built and pushed)
        $successful = 0
        $failed = 0
        
        foreach ($module in $modulesToDeploy) {
            $result = Deploy-Module -Module $module -ForceRedeploy $Force
            if ($result) {
                $successful++
            } else {
                $failed++
            }
        }
        
        # Show final status
        Show-DeploymentStatus
        
        # Show summary
        Show-Summary -Successful $successful -Failed $failed -Total $modulesToDeploy.Count
        
        if ($failed -gt 0) {
            Write-WarnLog "Some modules failed to deploy. Check logs for details."
            exit 1
        }
        
        Write-Success "All edge modules deployed successfully!"
        
    }
    catch {
        Write-ErrorLog "Deployment failed: $_"
        Write-ErrorLog $_.Exception.Message
        Write-ErrorLog "Stack Trace: $($_.ScriptStackTrace)"
        
        Write-Host "`n============================================================================" -ForegroundColor Red
        Write-Host "Edge Module Deployment Failed!" -ForegroundColor Red
        Write-Host "============================================================================" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host "Check log file for details: $script:LogFile" -ForegroundColor Red
        Write-Host ""
        
        exit 1
    }
    finally {
        # Only clean up proxy if it was actually started
        if ($script:ProxyStarted) {
            Stop-ArcProxies
        }
        # Cleanup legacy job if present
        if ($script:ProxyJob) {
            Stop-Job -Job $script:ProxyJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:ProxyJob -ErrorAction SilentlyContinue
        }
        
        Stop-Transcript
    }
}

# Execute main function
Main

#endregion
