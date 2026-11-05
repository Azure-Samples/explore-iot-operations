#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\scripts\AkriDocumentPolicy.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\AkriWorkflowProgress.ps1')

$allowedMcpServer = 'akri-connectors-mcp'
$script:toolEventRepositoryRoot = $null
$script:diagnosticToolName = ''
$builtInTools = @(
    'agent',
    'apply_patch',
    'ask-user',
    'ask_user',
    'bash',
    'create',
    'edit',
    'execute',
    'glob',
    'grep',
    'list_agents',
    'list_bash',
    'powershell',
    'read',
    'read_agent',
    'read_bash',
    'read_powershell',
    'rg',
    'search',
    'semantic_code_search',
    'skill',
    'stop_agent',
    'str_replace_editor',
    'task',
    'update_todo',
    'view',
    'web',
    'web_fetch',
    'web_search',
    'write_agent'
)
$pathArgumentNames = @(
    'file',
    'filePath',
    'file_path',
    'files',
    'directory',
    'directoryPath',
    'directory_path',
    'directories',
    'destination',
    'destinationPath',
    'destination_path',
    'inputPath',
    'input_path',
    'outputDirectory',
    'output_directory',
    'outputPath',
    'output_path',
    'path',
    'paths',
    'root',
    'searchPath',
    'search_path',
    'specPath',
    'spec_path',
    'target',
    'workspace',
    'workspacePath',
    'workspace_path'
)

function Deny-ToolUse {
    param([Parameter(Mandatory)][string]$Reason, [string]$Code = 'policy-denied')

    if ($script:toolEventRepositoryRoot) {
        try {
            Write-AkriToolActivity -RepositoryRoot $script:toolEventRepositoryRoot -Denied `
                -ToolName $script:diagnosticToolName -DenialCode $Code
        } catch { } # A failed observation must not change the denial.
    }
    @{
        permissionDecision = 'deny'
        permissionDecisionReason = $Reason
    } | ConvertTo-Json -Compress
    exit 0
}

function Get-FullPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BasePath
    )

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expandedPath.StartsWith('~')) {
        $expandedPath = Join-Path $HOME $expandedPath.Substring(1).TrimStart('\', '/')
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($expandedPath)) {
        $expandedPath = Join-Path $BasePath $expandedPath
    }
    return [System.IO.Path]::GetFullPath($expandedPath)
}

function Resolve-PhysicalPath {
    param([Parameter(Mandatory)][string]$Path)

    $unresolvedSegments = [System.Collections.Generic.List[string]]::new()
    $candidate = $Path
    while (-not (Test-Path -LiteralPath $candidate)) {
        $leaf = Split-Path -Leaf $candidate
        if (-not $leaf) {
            return $Path
        }
        $unresolvedSegments.Insert(0, $leaf)
        $parent = Split-Path -Parent $candidate
        if (-not $parent -or $parent -eq $candidate) {
            return $Path
        }
        $candidate = $parent
    }

    $item = Get-Item -LiteralPath $candidate -Force
    $resolvedTarget = $item.ResolveLinkTarget($true)
    $resolved = if ($null -ne $resolvedTarget) {
        $resolvedTarget.FullName
    } else {
        $item.FullName
    }
    foreach ($segment in $unresolvedSegments) {
        $resolved = Join-Path $resolved $segment
    }
    return [System.IO.Path]::GetFullPath($resolved)
}

function Test-IsWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $rootWithSeparator = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Equals($Root, $comparison) -or $Path.StartsWith($rootWithSeparator, $comparison)
}

function Test-AllowedUrl {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string[]]$AllowedDomains
    )

    if ($Uri.Scheme -ne 'https') {
        return $false
    }

    $hostName = $Uri.DnsSafeHost.ToLowerInvariant()
    foreach ($domain in $AllowedDomains) {
        if ($hostName -eq $domain -or $hostName.EndsWith(".$domain")) {
            return $true
        }
    }
    return $false
}

function Get-StringValues {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        $Value
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            Get-StringValues $entry.Value
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) {
            Get-StringValues $entry
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Get-StringValues $property.Value
    }
}

function Get-NamedArgumentValues {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Value) {
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -in $Names) {
            Get-StringValues $property.Value
        }
        if ($property.Value -isnot [string]) {
            Get-NamedArgumentValues $property.Value $Names
        }
    }
}

function Test-ToolNameAllowed {
    param([Parameter(Mandatory)][string]$ToolName)

    if ($ToolName -in $builtInTools) {
        return $true
    }
    $escapedServer = [regex]::Escape($allowedMcpServer)
    return $ToolName -match "^(?:mcp__)?$escapedServer(?:/|__|:|-).+$"
}

function Test-DocumentReaderToolName {
    param([Parameter(Mandatory)][string]$ToolName)

    $escapedServer = [regex]::Escape($allowedMcpServer)
    return $ToolName -match "^(?:mcp__)?$escapedServer(?:/|__|:|-)read-input-document$"
}

function Test-GroundingIndexReaderToolName {
    param([Parameter(Mandatory)][string]$ToolName)

    $escapedServer = [regex]::Escape($allowedMcpServer)
    return $ToolName -match "^(?:mcp__)?$escapedServer(?:/|__|:|-)read-grounding-index$"
}

function Test-UrlFetchToolName {
    param([Parameter(Mandatory)][string]$ToolName)

    $escapedServer = [regex]::Escape($allowedMcpServer)
    return $ToolName -match "^(?:mcp__)?$escapedServer(?:/|__|:|-)(?:fetch-url|fetch-microsoft-url)$"
}

function Get-TrustedDocumentScriptPaths {
    $scriptsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts'))
    Join-Path $scriptsRoot 'Set-AkriInputDocumentPolicy.ps1'
}

function Get-DocumentPolicyPath {
    param([Parameter(Mandatory)][string]$GitRoot)

    $policyPathOutput = @(& git -C $GitRoot rev-parse --git-path akri-connector-builder/document-policy.json 2>$null)
    if ($LASTEXITCODE -ne 0 -or $policyPathOutput.Count -ne 1) {
        return
    }
    $policyPath = if ([System.IO.Path]::IsPathFullyQualified($policyPathOutput[0])) {
        $policyPathOutput[0]
    } else {
        Join-Path $GitRoot $policyPathOutput[0]
    }
    return [System.IO.Path]::GetFullPath($policyPath)
}

function Get-TrustedPluginCommandPaths {
        param([Parameter(Mandatory)][string]$Command)
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or
            $ast.DynamicParamBlock -or $ast.UsingStatements.Count -or
            ($ast.PSObject.Properties['CleanBlock'] -and $ast.PSObject.Properties['CleanBlock'].Value) -or
            $ast.EndBlock.Statements.Count -ne 1) { return }
        $pipeline = $ast.EndBlock.Statements[0]
        if ($pipeline -isnot [Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1 -or $pipeline.Background) { return }
        $invocation = $pipeline.PipelineElements[0]
        if ($invocation -isnot [Management.Automation.Language.CommandAst] -or $invocation.Redirections.Count -or
            $invocation.InvocationOperator -notin @(
                [Management.Automation.Language.TokenKind]::Unknown,
                [Management.Automation.Language.TokenKind]::Ampersand
            )) { return }
        # Literal strings, string-only array literals, bare integers (timeouts), and argument-free parameter names only.
        if (@($invocation.CommandElements | Where-Object {
            $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] -and
            -not ($_ -is [Management.Automation.Language.ConstantExpressionAst] -and $_.Value -is [int]) -and
            -not ($_ -is [Management.Automation.Language.ArrayLiteralAst] -and -not @($_.Elements | Where-Object {
                $_ -isnot [Management.Automation.Language.StringConstantExpressionAst] }).Count) -and
            $_ -isnot [Management.Automation.Language.CommandParameterAst] -or
            ($_ -is [Management.Automation.Language.CommandParameterAst] -and $null -ne $_.Argument)
        }).Count) { return }
        $values = @($invocation.CommandElements | ForEach-Object {
            if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
            elseif ($_ -is [Management.Automation.Language.ArrayLiteralAst]) { $_.Elements | ForEach-Object Value }
        })
        $scriptRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts'))
        $trustedScripts = @('Set-AkriInputDocumentPolicy.ps1', 'Invoke-AkriConnectorWorkflow.ps1',
            'Receive-AkriWorkflowHeartbeat.ps1', 'Get-AkriVerificationFingerprint.ps1',
            'Get-AkriValidationCacheKey.ps1', 'Invoke-AkriRustContainerValidation.ps1',
            'New-AkriStepFailureReceipt.ps1') |
            ForEach-Object { Join-Path $scriptRoot $_ }
        $selectedIndex = 0
        if ($values[0] -in @('pwsh', 'pwsh.exe')) {
            $fileArgument = @($invocation.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ieq 'File'
            })
            if ($fileArgument.Count -ne 1) { return }
            $position = [Array]::IndexOf(@($invocation.CommandElements), $fileArgument[0]) + 1
            if ($position -ge $invocation.CommandElements.Count) { return }
            for ($index = 1; $index -lt ($position - 1); $index++) {
                $element = $invocation.CommandElements[$index]
                if ($element -isnot [Management.Automation.Language.CommandParameterAst] -or
                    $element.ParameterName -notin @('NoLogo', 'NoProfile', 'NonInteractive')) { return }
            }
            $selectedIndex = $position
        }
        $selectedElement = $invocation.CommandElements[$selectedIndex]
        if ($selectedElement -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return }
        $selected = $selectedElement.Value
        if ($selected -notin $trustedScripts) { return }
        if (-not (Test-Path -LiteralPath $selected -PathType Leaf) -or
            -not (Test-IsWithinRoot (Resolve-PhysicalPath $selected) (Resolve-PhysicalPath $scriptRoot))) { return }
        $argumentPaths = @(
            for ($index = 0; $index -lt $invocation.CommandElements.Count; $index++) {
                if ($index -eq $selectedIndex) { continue }
                $element = $invocation.CommandElements[$index]
                $literals = if ($element -is [Management.Automation.Language.ArrayLiteralAst]) {
                    $element.Elements
                } elseif ($element -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    @($element)
                } else { @() }
                foreach ($literal in $literals) {
                    if ([IO.Path]::IsPathFullyQualified($literal.Value)) {
                        [pscustomobject]@{ Path = $literal.Value; Text = $literal.Extent.Text }
                    }
                }
            }
        )
        [pscustomobject]@{
            ScriptPath = $selected
            ScriptText = $selectedElement.Extent.Text
            ArgumentPaths = $argumentPaths
        }
}

function Get-ProtectedDocumentPaths {
    param([Parameter(Mandatory)][string]$GitRoot)

    $policyPath = Get-DocumentPolicyPath $GitRoot
    if (-not $policyPath) {
        return
    }
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        return
    }
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    if ($policy.version -ne 1 -or
        $policy.classification -ne 'untrusted-document-data' -or
        $policy.instructionAuthority -ne 'none') {
        throw "Document policy '$policyPath' is invalid."
    }
    if ((Resolve-PhysicalPath ([string]$policy.repositoryRoot)) -ne $GitRoot) {
        throw "Document policy '$policyPath' belongs to a different repository."
    }
    foreach ($document in $policy.documents) {
        $documentPath = Resolve-PhysicalPath ([string]$document.fullPath)
        if (-not (Test-IsWithinRoot $documentPath $GitRoot)) {
            throw "Document policy '$policyPath' contains a path outside the active Git repository."
        }
        $documentPath
    }
}

try {
    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Deny-ToolUse 'Akri connector policy could not inspect an empty tool request.' -Code invalid-request
    }

    $request = $rawInput | ConvertFrom-Json
    $contentPolicy = Read-AkriContentPolicy
    $toolName = [string]$request.toolName
    $script:diagnosticToolName = $toolName
    $workingDirectory = [string]$request.cwd
    if (-not $toolName -or -not $workingDirectory) {
        Deny-ToolUse 'Akri connector policy received an incomplete tool request.' -Code invalid-request
    }

    $gitRootOutput = @(& git -C $workingDirectory rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $gitRootOutput.Count -ne 1) {
        Deny-ToolUse "The agent must execute inside a Git repository; '$workingDirectory' is not in one." -Code repository-required
    }
    $gitRoot = Resolve-PhysicalPath (Get-FullPath $gitRootOutput[0] $workingDirectory)
    $script:toolEventRepositoryRoot = $gitRoot
    $physicalWorkingDirectory = Resolve-PhysicalPath (Get-FullPath $workingDirectory $workingDirectory)
    if (-not (Test-IsWithinRoot $physicalWorkingDirectory $gitRoot)) {
        Deny-ToolUse "The tool working directory '$workingDirectory' is outside the active Git repository." -Code outside-repository
    }
    if (-not (Test-ToolNameAllowed $toolName)) {
        Deny-ToolUse "Tool '$toolName' is not a built-in tool or part of the '$allowedMcpServer' MCP server." -Code unsupported-tool
    }

    if ($toolName -in @('web', 'web_fetch', 'web_search')) {
        Deny-ToolUse "Direct web tool '$toolName' is disabled. Use the '$allowedMcpServer/fetch-url' MCP tool." -Code direct-web
    }

    $protectedDocumentPaths = @(Get-ProtectedDocumentPaths $gitRoot)
    $documentPolicyPath = Get-DocumentPolicyPath $gitRoot
    $trustedDocumentScriptPaths = @(Get-TrustedDocumentScriptPaths)
    $shellCommand = ''
    if ($toolName -in @('bash', 'execute', 'powershell')) {
        $commandArgument = $request.toolArgs.PSObject.Properties['command']
        if (-not $commandArgument -or $commandArgument.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($commandArgument.Value)) {
            Deny-ToolUse 'Shell requests must provide a non-empty command string.' -Code invalid-request
        }
        $shellCommand = $commandArgument.Value
    }
    $trustedPluginCommand = if ($shellCommand) { Get-TrustedPluginCommandPaths $shellCommand }
    $trustedDocumentCommand = $trustedPluginCommand -and
        $trustedPluginCommand.ScriptPath -in $trustedDocumentScriptPaths
    $trustedDocumentMcpTool = Test-DocumentReaderToolName $toolName
    $trustedDocumentAccess = $trustedDocumentCommand -or $trustedDocumentMcpTool
    $trustedGroundingIndexAccess = Test-GroundingIndexReaderToolName $toolName

    if (Test-UrlFetchToolName $toolName) {
        foreach ($value in @(Get-StringValues $request.toolArgs)) {
            foreach ($match in [regex]::Matches($value, '(?i)\bhttps?://[^\s<>"''`]+')) {
                $candidate = $match.Value.TrimEnd('.', ',', ';', ':', ')', ']', '}')
                $uri = $null
                if (-not [uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -or
                    -not (Test-AllowedUrl $uri $contentPolicy.allowedUrlDomains)) {
                    Deny-ToolUse "URL '$candidate' is outside the domains allowed by content-policy.yaml." -Code url-domain
                }
            }
        }
    }

    $paths = @(Get-NamedArgumentValues $request.toolArgs $pathArgumentNames)
    if ($toolName -eq 'apply_patch') {
        foreach ($value in @(Get-StringValues $request.toolArgs)) {
            foreach ($match in [regex]::Matches($value, '(?m)^\*\*\* (?:Add|Delete|Update|Move to) File: (.+)$')) {
                $paths += $match.Groups[1].Value.Trim()
            }
        }
    }
    if (-not $trustedDocumentCommand -and
        $protectedDocumentPaths.Count -gt 0 -and
        $toolName -in @('grep', 'rg', 'search', 'semantic_code_search') -and
        $paths.Count -eq 0) {
        Deny-ToolUse "Repository-wide search is prohibited while protected input documents are registered. Search a specific source directory instead." -Code unscoped-search
    }
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '.') {
            continue
        }
        $resolvedPath = Resolve-PhysicalPath (Get-FullPath $path $workingDirectory)
        if (-not (Test-IsWithinRoot $resolvedPath $gitRoot)) {
            Deny-ToolUse "File access to '$path' is outside the active Git repository '$gitRoot'." -Code outside-repository
        }
        if (-not $trustedDocumentAccess -and
            $documentPolicyPath -and
            $resolvedPath.Equals($documentPolicyPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Deny-ToolUse 'Direct access to the generated input-document policy is prohibited.' -Code document-policy
        }
        if (-not $trustedDocumentAccess -and $resolvedPath -in $protectedDocumentPaths) {
            Deny-ToolUse "Direct access to input document '$path' is prohibited. Use the '$allowedMcpServer/read-input-document' MCP tool." -Code protected-document
        }
        $normalizedResolvedPath = $resolvedPath.Replace('\', '/')
        if (-not $trustedGroundingIndexAccess -and
            $normalizedResolvedPath.EndsWith('/.spec/grounding-index.json', [System.StringComparison]::OrdinalIgnoreCase) -and
            $toolName -in @('bash', 'execute', 'powershell', 'read', 'view', 'grep', 'rg', 'search', 'semantic_code_search')) {
            Deny-ToolUse "Direct read access to grounding index '$path' is prohibited. Use the '$allowedMcpServer/read-grounding-index' MCP tool." -Code grounding-index
        }
        if (-not $trustedDocumentAccess -and
            $toolName -in @('grep', 'rg', 'search', 'semantic_code_search') -and
            ($protectedDocumentPaths | Where-Object { Test-IsWithinRoot $_ $resolvedPath } | Select-Object -First 1)) {
            Deny-ToolUse "Search scope '$path' contains a protected input document. Narrow the search to source paths that do not contain input documents." -Code protected-search
        }
    }

    if ($toolName -in @('bash', 'execute', 'powershell')) {
        $command = $shellCommand
        if ($command -match '(?i)\bhttps?://') {
            Deny-ToolUse "Shell URL access is prohibited. Use the '$allowedMcpServer/fetch-url' MCP tool." -Code shell-network
        }
        if (-not $trustedDocumentCommand) {
            if ($protectedDocumentPaths.Count -gt 0 -and
                $command -match '(?i)(?:^|[;&|]\s*)(?:cat|grep|more|rg|type|Get-Content|Select-String)\b') {
                Deny-ToolUse 'Shell content-reading and search commands are prohibited while protected input documents are registered.' -Code shell-content
            }
            if ($documentPolicyPath -and
                $command.Contains($documentPolicyPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Deny-ToolUse 'Shell access to the generated input-document policy is prohibited.' -Code document-policy
            }
            foreach ($protectedDocumentPath in $protectedDocumentPaths) {
                $relativeDocumentPath = [System.IO.Path]::GetRelativePath($gitRoot, $protectedDocumentPath)
                if ($command.Contains($protectedDocumentPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $command.Contains($relativeDocumentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Deny-ToolUse "Shell access to protected input document '$relativeDocumentPath' is prohibited. Use the '$allowedMcpServer/read-input-document' MCP tool." -Code protected-document
                }
            }
        }
        if ($command -match '(?i)(?:^|[\s''"])(?:~[/\\]|\$(?:HOME|USERPROFILE)\b|%USERPROFILE%|`?\$env:(?:HOME|USERPROFILE)\b)') {
            Deny-ToolUse 'Shell commands may not reference the user profile or home directory.' -Code home-directory
        }
        if ($command -match '(?:^|[\s\\/])\.\.(?:[\\/]|$)') {
            Deny-ToolUse 'Shell commands may not use parent-directory traversal.' -Code parent-traversal
        }

        $pathPatterns = if ($IsWindows) {
            @('(?i)(?:[A-Z]:[\\/][^\s''"`|;&<>]*)', '(?:\\\\[^\s''"`|;&<>]+)')
        } else {
            @('(?<![:\w])/(?:[^\s''"`|;&<>]+)')
        }
        $pathScanCommand = $command
        if ($trustedPluginCommand) {
            foreach ($argument in $trustedPluginCommand.ArgumentPaths) {
                if (-not (Test-IsWithinRoot (Resolve-PhysicalPath $argument.Path) $gitRoot)) {
                    Deny-ToolUse 'Plugin script arguments must remain inside the active repository.' -Code outside-repository
                }
                $pathScanCommand = $pathScanCommand.Replace($argument.Text, 'validated-repository-path')
            }
            $pathScanCommand = $pathScanCommand.Replace($trustedPluginCommand.ScriptText, 'validated-plugin-script')
        }
        foreach ($pattern in $pathPatterns) {
            foreach ($match in [regex]::Matches($pathScanCommand, $pattern)) {
                $candidatePath = $match.Value.TrimEnd(',', '.', ')', ']', '}')
                $resolvedPath = Resolve-PhysicalPath (Get-FullPath $candidatePath $workingDirectory)
                if (-not (Test-IsWithinRoot $resolvedPath $gitRoot)) {
                    Deny-ToolUse "Shell path '$candidatePath' is outside the active Git repository '$gitRoot'." -Code outside-repository
                }
            }
        }
    }

    Write-AkriToolActivity -ToolName $toolName -RepositoryRoot $gitRoot
    '{}'
} catch {
    @{
        permissionDecision = 'deny'
        permissionDecisionReason = "Akri connector policy failed closed: $($_.Exception.Message)"
    } | ConvertTo-Json -Compress
    exit 2
}

# SIG # Begin signature block
# MIInQAYJKoZIhvcNAQcCoIInMTCCJy0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAuhA1OmjyoBoN5
# KRaq8NxP1wMy+H6KwMUp4wekE2/T2qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghncMIIZ2AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIFQYycVGOUwjVICEBUTwjynktaMcADkzpv1HWvdGDQ9CMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAK2/pd4RhgqcRtZtz
# kIcJm543JnBAwxGM6pPPugvM3+acSROIzUCShut2o3MdwF2QdJ+S1cNgUbqh6uRa
# CrwYmVWel/gCQd7Q66kQbgakSqQ7iJRNu0u30yDiNhoU+6/yUet7E3RiBepOg18j
# jJrJzS6qcJ03CZiU90V5MLXfB448n0N30HzaHPNRBRKhBPaDxlt7p2UYbo1SNRux
# XDRsouD7QsNg5Xzu5n6J7+oavZn9FIlEaq/+fyARv6UAVfdHDfsg9eFkE8daDSO3
# aD/WoE6EK3BIs6XVXqPx9vuk1NbXkk/BleIofmSpKSqpEYkvujMYkaD/Bc63q2dG
# Ohqk3KGCF6wwgheoBgorBgEEAYI3AwMBMYIXmDCCF5QGCSqGSIb3DQEHAqCCF4Uw
# gheBAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFE
# MIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD04B0ZaHE+f0zO
# YI2G3uIH23d31K58qmreroHP0ymuHgIGauvjm6HrGBIyMDI2MTEwNTIxNTkwMS42
# NVowBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGlt
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU5MUEtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR+zCCBygwggUQ
# oAMCAQICEzMAAAI494TFhCu+5OQAAQAAAjgwDQYJKoZIhvcNAQELBQAwfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjYxMDE1MTgzNzQ3WhcNMjgwMTEx
# MTgzNzQ3WjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEt
# MCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NTkxQS0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDYw6K9AQa01hseA/LTRbENc2ZOIK5Vzgaa5f3d8Kn766e4
# 1lsmJqmTjr+bt7DT325Wr6AbLGM42JTKG3PZFPudR5kl8f5dF16y1RX4BFRkrB/N
# rzVi1qgKCC/ZvobviPbGO/5WXOOCHGbna6vq2Hf87fH9A/TV9Tjww1iHOZZK3z0+
# ijxF9rNLbYFtxxGDOcwj/+NKVyP07cSeYmLC83ZZil0lDXWcpmUm/w/6QE90OnzQ
# hPl7DURJZ0hWiX8h05DRGIwSQsb10RTYvICP8NQMvDcMeuN6/5N2EkndSWhPSiu/
# /QOJzaic4uoq1XnocL+3OsRg0xslTo8J9DiOZ3pL7B+n5A/TGT3l6+7s4nffV5iY
# oJ4A2Yj++QVLVHvawRxCvmRQouBj7tmAtVObzyEdvtbdstWf7aY+1rj1lhChqnaY
# kdNYDwRoxVSHyFf9ZMC8PIIPoiao9a0RAVLjRnJMitmQKLCeFj7c+DUeYR+sUewG
# 4e8BVCUp6XrH808Ac+fKwO2UuUlZ8VtU9nvqkID1fQMoxBmr1r/Am10ruKPtNVef
# 7cUM+3eHU88ltrNGSuQ18j9nEb7RmxFceFn4uOAxoh82u7qHvRCKzmn2yGheeLAM
# GoToUszjg5TJgJoh27uVHrWzRA8PjPGi51W0xIr1OvOL9K3mWMHAimhQq/XBMQID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFE2VeozchTpFMGV6D/x2Rl9XQuy6MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQBg4+DBBLd+xa5MCNa1UR8A2LHLlLEJsLS0IES5
# McevXtFWkKvFS0ur6Z51Wt6VwsJ7aeWcK2xvzACa3xLQDs2NMFSnxMAyCpNN5b4g
# tqbNFmEC0K2T2a+XM8afb1+Vco2JXsCDf0Dksf3v/YxsobYqmsXoXUFS1A7QvDpW
# DRNT21mHfB6oPMGnkz5ZjS1X1yP2FM70D1Gck1aMuRVbn5rWKASu1Ro8SPuPqO1P
# swmJ5wE7sx7W4x/x1TWXN3JfrRLaexWUeBKL+DotBtm8hRg3BxY9YMgGWg/FdLm5
# d2sd6fid3fcZiyzMsFSj9Y3L6vF1bAaQ/IwV5kMwScx8WlbpTZL6ta9jZxMaQ6LT
# Hsrpvbh4c1cFckNqEt/BXiD7XXLa4pUmqGWkmusIlvoW0JvxMy7NoOHktU+SNXCF
# ElZ0Jsng26pFrCBVDS56MgV2pC2QVdGrdmh4+g3KbW8CbQ/X+vauamJeVO6TwH+x
# TFp//1UJrRVXeUF6hhmH7WPo4OBtmnKYzwVxm2QO3g0PNdNBNuFx4FlHQ6DS/nQg
# gAuKcyQV856GmwcDpgAdBNoBmNrdVezQZa4J+C5WjdLuBeIUkaKPfhVJ+t4Rkc2h
# yk6uPqYqYO2j5afibYpAU8mfl9kB7dvaLb9Y2ciug4LFEwjbg2QmlFz717+9KTZq
# LVKmITCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNWMIIC
# PgIBATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGlt
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU5MUEtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4D
# AhoDFQBc+ChhD6tBwdsbRzmBXx7xDDPb5aCBgzCBgKR+MHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7pcKvzAiGA8yMDI2MTEw
# NTE0MDEzNVoYDzIwMjYxMTA2MTQwMTM1WjB0MDoGCisGAQQBhFkKBAExLDAqMAoC
# BQDulwq/AgEAMAcCAQACAi7XMAcCAQACAhI6MAoCBQDumFw/AgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBADOgXgd3muH8y0U79mLVjJoAujqF7QD5NKHxLCKT
# JFJktiJAFgJxPdDjry0NA/qBxtKJC5WOl5xEM9BBzcL3FIFF0b6nAJedXG2qm4uh
# wu9T1wYuE14mJj7mOXYnrSlJui1lQnpF0+03WjTSK/20AOO8xUY3T13ghkOn34Jo
# LHDnamQC85+MT/og4mFeeifkv6D5P9Un3O0NsPx3WesCAXYGoKWTM8NpxQhvkf0N
# rI+ZQ7Fxc4Nr/Q5FAQ95UHDto5zT9iQKql8jxYahoMk8VcjYdKhHtWpVwRLv686F
# g4ulld2u+MIsQ51MDF+xXvS8P/5W8tJYG8Xhwl3HXy0cDGcxggQNMIIECQIBATCB
# kzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAjj3hMWEK77k5AAB
# AAACODANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJ
# EAEEMC8GCSqGSIb3DQEJBDEiBCA1apFp3S3J8j0U0Av1KLXfsbzZXVbHVgUBY6/+
# MsdSPzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIA56xCA0DqqhO7f128Pw
# Q+63r8p/rY2B0q5Y8YtbCeK1MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAI494TFhCu+5OQAAQAAAjgwIgQgiKeBoSgzYm41AQK/JG0d
# zW4FSIE2iDGbdtd2pdpo5WQwDQYJKoZIhvcNAQELBQAEggIAMCAfug8TXhNmfsZJ
# jijBoWRiHFvRemEMq3WASpJEId3ykScCoChfTH0CCDNVEhnGlNKaLwxWXp4qc8Br
# Ms2HVtztZiT6xoDVfCwV5jEZF723NLGZR/w3L09Gbi0IQ+8852J8HnYkmZuylR9l
# /RprIFhl9leW0wuA7zOpyeiMH9k3rAooun7rUvQiKKytEsQMuTaDWvbgT8KU4VGH
# A2Z5nHJ8jaTH3pmsGvFjP8pYo/BE+CQVanTtDJ9C2zDKUUL/fxNtGZoDwVCmAzEu
# vn42tONXRFJFChcd8RbyskmY0Wm/VrSjw0I96I7CwNIO3h/jjDpxIiCtohgYHeuQ
# NyxGVUthtrH2f9IvIV+rgcundu8QzV50kCjKgSGWnLNuwQ7Dn9fJAZNURN5GwQU2
# GXbp0+ms6F7aHYVAGAzZVjeBXiOGpphyrjCmX2bm0q/jT66DYoQmEep7+47Cj6pB
# 0dlxdYjb7Rb9Xvtq38kapzwYzMQDkYU3mhXANWrfxcG9kpYH5m+clm8fFP5PmrIg
# 6vSKDGW+FrybqW3wWKeMCOq7Cr2czD2jgDHP/TBBlj8FNYVkWO28BxoSr9RMQnVD
# eZf2euuo/pnPVBIKQ1YHqr++p2nEdwRwwOM2SKeqvdeooa4yPbwRU6M1OBGnNZtt
# 1YJV9MiFRNFlTuWgitDFcAlopi4=
# SIG # End signature block
