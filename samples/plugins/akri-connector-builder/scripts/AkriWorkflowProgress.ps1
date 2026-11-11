#requires -Version 7.0

. (Join-Path $PSScriptRoot 'AkriCredentialRedaction.ps1')

function ConvertTo-AkriProgressText {
    param([Parameter(Mandatory)][string]$Text)

    $safe = (Protect-CredentialText $Text).Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    $safe = ($safe -replace '[\x00-\x1F\x7F-\x9F]', ' ' -replace '\s+', ' ').Trim()
    if ($safe.Length -gt 240) { $safe = $safe.Substring(0, 240) }
    return $safe
}

function Write-AkriAtomicJson {
    param([string]$Path, [object]$Value)

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                [IO.File]::Move($temporaryPath, $Path, $true)
                return
            } catch [IO.IOException], [UnauthorizedAccessException] {
                # Windows readers can briefly prevent replacement; other I/O failures are not retried.
                $nativeCode = $_.Exception.HResult -band 0xffff
                if ($_.Exception.InnerException) { $nativeCode = $_.Exception.InnerException.HResult -band 0xffff }
                if (-not $IsWindows -or $nativeCode -notin @(5, 32, 33) -or $attempt -eq 4) { throw }
                [Console]::Error.WriteLine("Workflow checkpoint replacement blocked; retry $($attempt + 1)/4.")
                [Threading.Thread]::Sleep([int](50 * [Math]::Pow(2, $attempt)))
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
    }
}

function Assert-AkriProgressDirectory {
    param([string]$Path, [string]$RepositoryRoot)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath($Path)
    if (-not $candidate.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", $comparison)) {
        throw 'Workflow diagnostics must remain inside the active Git repository.'
    }
    while (-not $candidate.Equals($root, $comparison)) {
        if ((Test-Path -LiteralPath $candidate) -and
            ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Workflow diagnostics may not traverse symbolic links or junctions.'
        }
        $candidate = Split-Path -Parent $candidate
    }
}

function Get-AkriToolActivity {
    param([string]$ToolName)

    switch -Regex ($ToolName) {
        '^(read|view|glob|grep|rg|search|semantic_code_search)$' { return 'Reading or locating implementation evidence.' }
        '^(edit|create|apply_patch|str_replace_editor)$' { return 'Requesting a workspace edit.' }
        '^(bash|execute|powershell|read_bash|list_bash|stop_bash)$' { return 'Running or checking a command.' }
        '^(agent|task|read_agent|write_agent|list_agents|stop_agent)$' { return 'Working with a reviewer or nested worker.' }
        '^(?:mcp__)?akri-connectors-mcp(?:/|__|:|-)' { return 'Calling the Akri connector tooling.' }
        default { return 'Other authorized tool call.' }
    }
}

function Get-AkriDiagnosticToolName([string]$ToolName) {
    $ToolName = ([string]$ToolName).ToLowerInvariant()
    if ($ToolName -cin @('agent', 'apply_patch', 'ask-user', 'ask_user', 'bash', 'create', 'edit',
        'execute', 'glob', 'grep', 'list_agents', 'list_bash', 'powershell', 'read', 'read_agent',
        'read_bash', 'rg', 'search', 'semantic_code_search', 'skill', 'stop_agent', 'stop_bash',
        'str_replace_editor', 'task', 'update_todo', 'view', 'web', 'web_fetch', 'web_search',
        'write_agent')) { return $ToolName }
    foreach ($name in @('read-input-document', 'read-grounding-index', 'fetch-url', 'fetch-microsoft-url',
        'create-connector', 'build-connector',
        'start-development-environment', 'stop-development-environment', 'run-connector',
        'cleanup-connector', 'generate-support-bundle', 'list-configuration-files', 'manage-configuration', 'publish')) {
        if ($ToolName -cmatch ('^(?:mcp__)?akri-connectors-mcp(?:/|__|:|-)' + [regex]::Escape($name) + '$')) {
            return "akri-connectors-mcp/$name"
        }
    }
    return 'unknown'
}

function Get-AkriDiagnosticDenialCode([string]$Code) {
    if ($Code -cin @('invalid-request', 'unsupported-tool', 'repository-required', 'outside-repository',
        'direct-web', 'url-domain', 'unscoped-search', 'document-policy', 'protected-document',
        'grounding-index', 'protected-search', 'shell-network', 'shell-content', 'home-directory',
        'parent-traversal', 'policy-denied')) { return $Code }
    return 'policy-denied'
}

function Write-AkriToolActivity {
    param([string]$ToolName, [string]$RepositoryRoot, [switch]$Denied, [string]$DenialCode = 'policy-denied')

    $directory = $env:AKRI_WORKFLOW_TOOL_EVENTS
    if ([string]::IsNullOrWhiteSpace($directory)) { return }
    Assert-AkriProgressDirectory $directory $RepositoryRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'The workflow tool-activity directory is unavailable.'
    }
    if (@(Get-ChildItem -LiteralPath $directory -File | Select-Object -First 513).Count -ge 512) {
        throw 'The workflow tool-activity queue is full; inspect the orchestrator diagnostics.'
    }
    $path = Join-Path $directory "$([guid]::NewGuid().ToString('N')).json"
    $record = @{ version = 1; atUtc = [DateTimeOffset]::UtcNow.ToString('o')
        activity = $(if ($Denied) { 'Tool request denied by scoped policy.' } else { Get-AkriToolActivity $ToolName }) }
    if ($Denied) {
        $record.deniedTool = Get-AkriDiagnosticToolName $ToolName
        $record.denialCode = Get-AkriDiagnosticDenialCode $DenialCode
    }
    Write-AkriAtomicJson $path $record
}

function Get-AkriCodeObservation {
    param([string]$WorkspacePath)

    $files = @{}
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($WorkspacePath)
    $excluded = @('.git', '.vs', 'node_modules', 'target', 'bin', 'obj', 'Output', 'coverage',
        '__pycache__', '.pytest_cache', '.spec', 'conformance', 'user-docs', 'tech-docs')
    $extensions = @('.rs', '.cs', '.fs', '.vb', '.c', '.cpp', '.h', '.hpp', '.go', '.py',
        '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx', '.java', '.kt', '.sh', '.ps1',
        '.toml', '.csproj', '.fsproj', '.props', '.targets', '.sln', '.slnx', '.json',
        '.yaml', '.yml', '.config', '.xml')
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            if (-not (Test-Path -LiteralPath $directory -PathType Container -ErrorAction Stop)) { continue }
            if ((Get-Item -LiteralPath $directory -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        } catch [System.Management.Automation.ItemNotFoundException], [IO.DirectoryNotFoundException], [IO.FileNotFoundException] {
            if (Test-Path -LiteralPath $directory -ErrorAction Stop) { throw }
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.PSIsContainer) {
                if ($entry.Name -notin $excluded) { $pending.Push($entry.FullName) }
            } elseif ($entry.Extension -in $extensions -or $entry.Name -like 'Dockerfile*' -or
                $entry.Name -in @('Cargo.lock', 'Makefile', 'CMakeLists.txt', '.editorconfig', '.dockerignore', '.gitignore')) {
                $relative = [IO.Path]::GetRelativePath($WorkspacePath, $entry.FullName)
                $files[$relative] = "$($entry.Length):$($entry.LastWriteTimeUtc.Ticks)"
            }
        }
    }
    return $files
}

function Write-AkriProgressEvent {
    param([object]$Monitor, [string]$Kind, [string]$Activity, [string]$DeniedTool, [string]$DenialCode)

    Assert-AkriProgressDirectory $Monitor.Directory $Monitor.RepositoryRoot
    $step = $Monitor.CurrentStep
    $record = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
        RunId = $Monitor.RunId
        Kind = $Kind
        StepId = if ($step) { $step.Id } else { $null }
        Attempt = if ($step) { $step.Attempt } else { $null }
        Model = if ($step) { $step.Model } else { $null }
        Reasoning = if ($step) { $step.Reasoning } else { $null }
        WorkerExitCode = if ($step) { $step.LastWorkerExitCode } else { $null }
        DiagnosticCode = if ($step) { $step.DiagnosticCode } else { $null }
        Activity = ConvertTo-AkriProgressText $Activity
        OpenFindings = if ($step) { $step.OpenFindings } else { $null }
        OpenFindingCount = if ($step) { $step.OpenFindingCount } else { $null }
    }
    if ($Kind -ceq 'tool-denied') {
        $record.DeniedTool = Get-AkriDiagnosticToolName $DeniedTool
        $record.DenialCode = Get-AkriDiagnosticDenialCode $DenialCode
    }
    $text = ($record | ConvertTo-Json -Compress -Depth 5) + "`n"
    $path = Join-Path $Monitor.Directory 'events.jsonl'
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The workflow diagnostic log may not be a symbolic link.'
        }
        if ((Get-Item -LiteralPath $path).Length + [Text.Encoding]::UTF8.GetByteCount($text) -gt $Monitor.MaximumLogBytes) {
            if (Test-Path -LiteralPath "$path.1") { [IO.File]::Move("$path.1", "$path.2", $true) }
            [IO.File]::Move($path, "$path.1", $true)
        }
    }
    [IO.File]::AppendAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function Save-AkriProgressStatus {
    param([object]$Monitor)

    $validation = $Monitor.Orchestrator.PSObject.Properties['Validation']?.Value
    if ($validation -and $validation.StartedAtUtc) {
        $validation.ElapsedSeconds = [Math]::Max(0, [int]([DateTimeOffset]::UtcNow -
            [DateTimeOffset]::Parse($validation.StartedAtUtc)).TotalSeconds)
    }
    Assert-AkriProgressDirectory $Monitor.Directory $Monitor.RepositoryRoot
    $status = [ordered]@{
        Version = 1
        RunId = $Monitor.RunId
        UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        HeartbeatIntervalSeconds = $Monitor.Interval
        Orchestrator = $Monitor.Orchestrator
        CurrentStep = $Monitor.CurrentStep
        Steps = @($Monitor.Steps)
    }
    $path = Join-Path $Monitor.Directory 'status.json'
    Write-AkriAtomicJson -Path $path -Value $status
}

function Format-AkriProgressStatus {
    param([object]$Monitor)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("AKRI workflow status | $([DateTimeOffset]::UtcNow.ToString('o')) | $($Monitor.Orchestrator.Status)")
    $lines.Add("Orchestrator started (UTC): $($Monitor.Orchestrator.StartedAtUtc)")
    $lines.Add("Orchestrator activity: $($Monitor.Orchestrator.LastActivity)")
    $validation = $Monitor.Orchestrator.PSObject.Properties['Validation']?.Value
    if ($validation) {
        $active = if ($validation.Operation) { $validation.Operation } else { 'none' }
        $last = if ($validation.LastCompleted) { $validation.LastCompleted } else { 'none yet' }
        $lines.Add("Active validation: $active | elapsed: $($validation.ElapsedSeconds)s")
        $lines.Add("Last completed validation operation: $last")
        if ($validation.InterruptedOperation) { $lines.Add("Interrupted validation operation: $($validation.InterruptedOperation)") }
    }
    foreach ($step in $Monitor.Steps) {
        $marker = if ($step.Status -eq 'passed') { 'x' } elseif ($step.Status -eq 'failed') { '!' } elseif (
            $Monitor.CurrentStep -and $step.Id -eq $Monitor.CurrentStep.Id) { '>' } else { ' ' }
        $lines.Add("[$marker] $($step.Order). $($step.Name)")
    }
    if ($Monitor.CurrentStep) {
        $step = $Monitor.CurrentStep
        $lines.Add("Current step started (UTC): $($step.StartedAtUtc)")
        $lines.Add("Attempt: $($step.Attempt) | model: $($step.Model) | reasoning: $($step.Reasoning)")
        foreach ($field in @(
            @{ Label = 'Last tool call started (UTC)'; Value = $step.LastToolCallAtUtc },
            @{ Label = 'Last tool request denied (UTC)'; Value = $step.LastToolDenialAtUtc },
            @{ Label = 'Last code activity observed (UTC)'; Value = $step.LastCodeActivityAtUtc }
        )) {
            $value = if ($field.Value) { $field.Value } else { 'not observed in this step' }
            $lines.Add("$($field.Label): $value")
        }
        $lines.Add("Last activity: $($step.LastActivity)")
        if ($step.LastDeniedTool) {
            $lines.Add("Last denied tool: $($step.LastDeniedTool) | policy check: $($step.LastDenialCode)")
        }
        $lines.Add("Last activity observed (UTC): $($step.LastActivityAtUtc)")
        $lines.Add("Progress: $($step.Progress)")
        if ($step.LastWorkerReport) { $lines.Add("Worker update: $($step.LastWorkerReport)") }
        if ($null -eq $step.OpenFindings) {
            $lines.Add('Open findings: not reported (this does not mean zero).')
        } else {
            $lines.Add("Worker-reported open findings: $($step.OpenFindingCount) | as of $($step.FindingsReportedAtUtc)")
            if ($step.OpenFindingCount -gt $step.OpenFindings.Count) {
                $lines.Add("Showing $($step.OpenFindings.Count) summaries; full findings remain in the workspace evidence.")
            }
            foreach ($finding in $step.OpenFindings) { $lines.Add("- $finding") }
        }
    }
    $lines.Add("Diagnostics: $($Monitor.Directory)")
    return $lines -join "`n"
}

function Publish-AkriProgressHeartbeat {
    param([object]$Monitor, [switch]$Force)

    $elapsed = $Monitor.Clock.Elapsed.TotalSeconds
    if (-not $Force -and $elapsed -lt $Monitor.NextHeartbeat) { return }
    if ($Monitor.CurrentStep) {
        $step = $Monitor.CurrentStep
        $step.Progress = if ($step.Status -eq 'passed') {
            'Accepted: every required gate and deterministic check passed.'
        } elseif ($step.Status -eq 'failed') {
            'Failed: execution or acceptance did not pass; inspect the diagnostic state.'
        } elseif ($Monitor.CodeChanges -gt 0 -or $Monitor.FindingsReduced) {
            'Edits or fewer worker-reported findings observed; acceptance gates remain independent.'
        } elseif ($Monitor.ActivityCount -gt 0) {
            'Activity observed; forward progress has not been established.'
        } else {
            'No new activity observed; a long-running tool may still be active. This is not proof of a hang.'
        }
    }
    Save-AkriProgressStatus $Monitor
    $Monitor.HeartbeatSequence++
    $text = Format-AkriProgressStatus $Monitor
    Write-AkriAtomicJson -Path (Join-Path $Monitor.Directory 'heartbeat.json') -Value ([ordered]@{
        Version = 1
        RunId = $Monitor.RunId
        Sequence = $Monitor.HeartbeatSequence
        PublishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Status = $Monitor.Orchestrator.Status
        Terminal = $Monitor.Orchestrator.Status -in @('completed', 'failed')
        UserMessage = $text
    })
    Write-AkriProgressEvent $Monitor 'heartbeat' 'Heartbeat checkpoint published; console output is not confirmation of user delivery.'
    # Direct terminals use stdout; captured/background hosts must relay heartbeat.json to chat.
    if ($Monitor.WriteToConsole) { [Console]::WriteLine($text) }
    $Monitor.NextHeartbeat = $elapsed + $Monitor.Interval
    $Monitor.CodeChanges = 0
    $Monitor.FindingsReduced = $false
    $Monitor.ActivityCount = 0
}

function Update-AkriCodeActivity {
    param([object]$Monitor)

    if (-not $Monitor.CurrentStep) { return }
    $current = Get-AkriCodeObservation $Monitor.Workspace
    $changes = @(@($current.Keys) + @($Monitor.CodeBaseline.Keys) | Select-Object -Unique |
        Where-Object { -not $current.ContainsKey($_) -or -not $Monitor.CodeBaseline.ContainsKey($_) -or
            $current[$_] -cne $Monitor.CodeBaseline[$_] }).Count
    $Monitor.CodeBaseline = $current
    $Monitor.NextCodeScan = $Monitor.Clock.Elapsed.TotalSeconds + [Math]::Min(5, $Monitor.Interval)
    if ($changes -gt 0) {
        $Monitor.CodeChanges += $changes
        $Monitor.CurrentStep.LastCodeActivityAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $Monitor.CurrentStep.LastActivityAtUtc = $Monitor.CurrentStep.LastCodeActivityAtUtc
        $Monitor.CurrentStep.LastActivity = "Source, tests, or build configuration changed ($changes files)."
        Write-AkriProgressEvent $Monitor 'code-activity' $Monitor.CurrentStep.LastActivity
        Save-AkriProgressStatus $Monitor
    }
}

function Receive-AkriToolActivity {
    param([object]$Monitor)

    if (-not $Monitor.ToolDirectory) { return }
    Assert-AkriProgressDirectory $Monitor.ToolDirectory $Monitor.RepositoryRoot
    $files = @(Get-ChildItem -LiteralPath $Monitor.ToolDirectory -Filter '*.json' -File)
    foreach ($file in $files) {
        if ($file.Length -gt 2048 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Invalid workflow tool-activity event.'
        }
        $event = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $at = if ($event.atUtc -is [DateTime]) { [DateTimeOffset]$event.atUtc }
            else { [DateTimeOffset]::Parse($event.atUtc, [Globalization.CultureInfo]::InvariantCulture) }
        $knownActivities = @('Reading or locating implementation evidence.', 'Requesting a workspace edit.',
            'Running or checking a command.', 'Working with a reviewer or nested worker.',
            'Calling the Akri connector tooling.', 'Other authorized tool call.', 'Tool request denied by scoped policy.')
        if ($event.version -ne 1 -or $event.activity -cnotin $knownActivities -or $at -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) {
            throw 'Invalid workflow tool-activity event.'
        }
        $step = $Monitor.CurrentStep
        $denied = $event.activity -ceq 'Tool request denied by scoped policy.'
        $deniedTool = Get-AkriDiagnosticToolName ([string]$event.PSObject.Properties['deniedTool']?.Value)
        $denialCode = Get-AkriDiagnosticDenialCode ([string]$event.PSObject.Properties['denialCode']?.Value)
        if ($step -and $denied -and (-not $step.LastToolDenialAtUtc -or $at -gt [DateTimeOffset]::Parse($step.LastToolDenialAtUtc))) {
            $step.LastToolDenialAtUtc = $at.ToString('o')
            $step.LastDeniedTool = $deniedTool
            $step.LastDenialCode = $denialCode
        }
        if ($step -and -not $denied -and (-not $step.LastToolCallAtUtc -or $at -gt [DateTimeOffset]::Parse($step.LastToolCallAtUtc))) {
            $step.LastToolCallAtUtc = $at.ToString('o')
            if ($at -ge [DateTimeOffset]::Parse($step.LastActivityAtUtc)) {
                $step.LastActivity = $event.activity
                $step.LastActivityAtUtc = $at.ToString('o')
            }
        }
        $Monitor.ActivityCount++
        Write-AkriProgressEvent $Monitor $(if ($denied) { 'tool-denied' } else { 'tool-call' }) $event.activity `
            -DeniedTool $deniedTool -DenialCode $denialCode
        Remove-Item -LiteralPath $file.FullName
    }
    if ($files.Count -gt 0) { Save-AkriProgressStatus $Monitor }
}

function ConvertFrom-AkriWorkerProgress {
    param([string]$Line, [string]$StepId)

    $prefix = 'AKRI_WORKFLOW_PROGRESS='
    $index = $Line.IndexOf($prefix, [StringComparison]::Ordinal)
    if ($index -lt 0) { return $null }
    if ($Line.Length -gt 64KB) { Stop-AkriWorkerProgress 'size' }
    try { $report = $Line.Substring($index + $prefix.Length).Trim() | ConvertFrom-Json } catch {
        Stop-AkriWorkerProgress 'json'
    }
    if ($null -eq $report -or @('version', 'stepId', 'activity').Where({ -not $report.PSObject.Properties[$_] }).Count -or
        $report.version -ne 1 -or $report.stepId -cne $StepId -or $report.activity -isnot [string] -or
        [string]::IsNullOrWhiteSpace($report.activity)) {
        Stop-AkriWorkerProgress 'step-version-activity'
    }
    $findingsProperty = $report.PSObject.Properties['openFindings']
    $findings = $null
    $count = $null
    if ($findingsProperty) {
        if ($findingsProperty.Value -isnot [array] -or $findingsProperty.Value.Count -gt 100) {
            Stop-AkriWorkerProgress 'findings-array'
        }
        $findings = @(
            foreach ($finding in $findingsProperty.Value) {
                if ($finding -isnot [string] -or [string]::IsNullOrWhiteSpace($finding)) {
                    Stop-AkriWorkerProgress 'finding-summary'
                }
                ConvertTo-AkriProgressText $finding
            }
        )
        $count = $findings.Count
        $countProperty = $report.PSObject.Properties['openFindingCount']
        if ($countProperty) {
            if (($countProperty.Value -isnot [int] -and $countProperty.Value -isnot [long]) -or
                $countProperty.Value -lt $findings.Count -or $countProperty.Value -gt [int]::MaxValue -or
                ($countProperty.Value -gt 0 -and $findings.Count -eq 0)) {
                Stop-AkriWorkerProgress 'finding-count'
            }

            $count = [int]$countProperty.Value
        }
    }
    return @{ Activity = ConvertTo-AkriProgressText $report.activity; HasFindings = [bool]$findingsProperty
        OpenFindings = $findings; OpenFindingCount = $count }
}

function Stop-AkriWorkerProgress {
    param([string]$Check)

    $exception = [InvalidOperationException]::new("Worker progress rejected [$Check].")
    $exception.Data['AkriProgressCheck'] = $Check
    throw $exception
}

function Update-AkriProgressMessage {
    param([object]$Monitor, [object]$Message)

    $kind = $Message.Kind
    $data = $Message.Data
    if ($kind -eq 'validation') {
        $previous = $Monitor.Orchestrator.Validation
        $Monitor.Orchestrator.Validation = [pscustomobject]@{
            Operation = $data.Operation; LastCompleted = $data.LastCompleted
            StartedAtUtc = $(if ($data.StartedAtUtc) { $data.StartedAtUtc } elseif ($data.Operation -and $previous) { $previous.StartedAtUtc } else { $null })
            ElapsedSeconds = 0
            InterruptedOperation = $null
        }
    } elseif ($kind -eq 'ready') {
        foreach ($step in $Monitor.Steps) {
            if ($step.Id -in $data.CompletedSteps) { $step.Status = 'passed' }
        }
    } elseif ($kind -eq 'step-started') {
        $Monitor.CurrentStep = $Monitor.Steps | Where-Object Id -CEQ $data.StepId
        $step = $Monitor.CurrentStep
        $step.Status = 'running'
        $step.StartedAtUtc = $Message.AtUtc
        $step.LastActivity = 'Step started; awaiting observations.'
        $step.LastActivityAtUtc = $Message.AtUtc
        $Monitor.CodeBaseline = Get-AkriCodeObservation $Monitor.Workspace
        $Monitor.CodeChanges = 0
        $Monitor.ActivityCount = 0
        $Monitor.FindingsReduced = $false
    } elseif ($kind -eq 'attempt-started') {
        $Monitor.ToolDirectory = $data.ToolDirectory
        $Monitor.CurrentStep.Attempt++
        $Monitor.CurrentStep.Model = $data.Model
        $Monitor.CurrentStep.Reasoning = $data.Reasoning
        $Monitor.CurrentStep.AttemptStartedAtUtc = $Message.AtUtc
        $Monitor.CurrentStep.LastWorkerExitCode = $null
    } elseif ($kind -eq 'attempt-ended') {
        $Monitor.CurrentStep.LastWorkerExitCode = $data.ExitCode
        Receive-AkriToolActivity $Monitor
        Update-AkriCodeActivity $Monitor
    } elseif ($kind -eq 'worker-progress') {
        $step = $Monitor.CurrentStep
        if ($data.HasFindings) {
            if ($null -ne $step.OpenFindingCount -and $data.OpenFindingCount -lt $step.OpenFindingCount) {
                $Monitor.FindingsReduced = $true
            }
            $step.OpenFindings = @($data.OpenFindings)
            $step.OpenFindingCount = $data.OpenFindingCount
            $step.FindingsReportedAtUtc = $Message.AtUtc
        }
        if ($step.LastWorkerReport -cne $data.Activity) { $Monitor.ActivityCount++ }
        $step.LastActivity = $data.Activity
        $step.LastActivityAtUtc = $Message.AtUtc
        $step.LastWorkerReport = $data.Activity
        if ($Monitor.WriteToConsole) { [Console]::WriteLine("Worker update: $($data.Activity)") }
    } elseif ($kind -in @('step-passed', 'step-failed')) {
        $Monitor.CurrentStep.Status = if ($kind -eq 'step-passed') { 'passed' } else { 'failed' }
        $Monitor.CurrentStep.FinishedAtUtc = $Message.AtUtc
        if ($kind -eq 'step-failed') { $Monitor.CurrentStep.DiagnosticCode = $data.Code }
    } elseif ($kind -eq 'failed' -and $Monitor.CurrentStep -and $Monitor.CurrentStep.Status -ne 'passed') {
        $Monitor.CurrentStep.Status = 'failed'
        $Monitor.CurrentStep.FinishedAtUtc = $Message.AtUtc
    }
    if ($kind -ne 'worker-progress') {
        $Monitor.Orchestrator.LastActivity = $data.Activity
        $Monitor.Orchestrator.LastActivityAtUtc = $Message.AtUtc
    }
    $Monitor.Orchestrator.Status = if ($kind -eq 'completed') { 'completed' } elseif (
        $kind -in @('failed', 'step-failed')) { 'failed' } else { 'running' }
    if ($kind -in @('failed', 'step-failed', 'completed') -and $Monitor.Orchestrator.Validation) {
        $validation = $Monitor.Orchestrator.Validation
        if ($kind -ne 'completed' -and $validation.Operation) { $validation.InterruptedOperation = $validation.Operation }
        $validation.Operation = $null
        $validation.StartedAtUtc = $null
    }
    Write-AkriProgressEvent $Monitor $kind $data.Activity
    Save-AkriProgressStatus $Monitor
    if ($kind -in @('step-started', 'step-passed', 'step-failed', 'completed', 'failed')) {
        Publish-AkriProgressHeartbeat $Monitor -Force
    }
}

function New-AkriProgressState {
    param([object]$Options, [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId = ([guid]::NewGuid().ToString('N')))

    $steps = @(
        foreach ($step in $Options.Steps) {
            [pscustomobject]@{
                Id = $step.Id; Name = $step.Name; Order = $step.DisplayOrder; Status = 'pending'
                StartedAtUtc = $null; FinishedAtUtc = $null; AttemptStartedAtUtc = $null
                LastToolCallAtUtc = $null; LastToolDenialAtUtc = $null; LastCodeActivityAtUtc = $null
                LastDeniedTool = $null; LastDenialCode = $null
                LastActivity = 'Not started.'; LastActivityAtUtc = $null; LastWorkerReport = $null
                OpenFindings = $null; OpenFindingCount = $null
                FindingsReportedAtUtc = $null; Progress = 'Not started.'; Attempt = 0; Model = $null; Reasoning = $null
                LastWorkerExitCode = $null; DiagnosticCode = $null
            }
        }
    )
    return [pscustomobject]@{
        RunId = $RunId; HeartbeatSequence = 0; Directory = $Options.Directory; Workspace = $Options.Workspace
        RepositoryRoot = $Options.RepositoryRoot
        Interval = $Options.Interval; MaximumLogBytes = 5MB; WriteToConsole = $true
        Clock = [Diagnostics.Stopwatch]::StartNew(); NextHeartbeat = 0; NextCodeScan = 0
        CurrentStep = $null; Steps = $steps; CodeBaseline = @{}; ToolDirectory = $null
        CodeChanges = 0; ActivityCount = 0; FindingsReduced = $false
        Orchestrator = [pscustomobject]@{
            Validation = $null
            StartedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); Status = 'starting'
            LastActivityAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); LastActivity = 'Starting orchestration.'
        }
    }
}

function Start-AkriProgressMonitor {
    param([string]$Directory, [string]$Workspace, [string]$RepositoryRoot, [object[]]$Steps, [int]$Interval,
        [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId = ([guid]::NewGuid().ToString('N')),
        [bool]$WriteToConsole = $true)

    Assert-AkriProgressDirectory $Directory $RepositoryRoot
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $control = [hashtable]::Synchronized(@{
        Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        Ready = [Threading.ManualResetEventSlim]::new($false)
        Stop = $false; Failure = $false
    })
    $options = @{ Directory = $Directory; Workspace = $Workspace; Steps = $Steps; Interval = $Interval
        RepositoryRoot = $RepositoryRoot; RunId = $RunId; WriteToConsole = $WriteToConsole }
    $runner = [powershell]::Create()
    $null = $runner.AddScript({
        param($library, $control, $options)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $lock = $null
        $monitor = $null
        try {
            . $library
            $lockPath = Join-Path $options.Directory '.lock'
            if ((Test-Path -LiteralPath $lockPath) -and
                ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'The workflow diagnostic lock may not be a symbolic link.'
            }
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $ignorePath = Join-Path $options.Directory '.gitignore'
            $ignoreTemporaryPath = Join-Path $options.Directory "$([guid]::NewGuid().ToString('N')).tmp"
            [IO.File]::WriteAllText($ignoreTemporaryPath, "*`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($ignoreTemporaryPath, $ignorePath, $true)
            $monitor = New-AkriProgressState -Options $options -RunId $options.RunId
            $monitor.WriteToConsole = $options.WriteToConsole
            Write-AkriProgressEvent $monitor 'orchestrator-started' 'Starting orchestration.'
            Publish-AkriProgressHeartbeat $monitor -Force
            $control.Ready.Set()
            while ($true) {
                $message = $null
                while ($control.Queue.TryDequeue([ref]$message)) {
                    try { Update-AkriProgressMessage $monitor $message } finally { [void]$message.Acknowledged.TrySetResult($true) }
                }
                Receive-AkriToolActivity $monitor
                if ($monitor.Clock.Elapsed.TotalSeconds -ge $monitor.NextCodeScan) { Update-AkriCodeActivity $monitor }
                Publish-AkriProgressHeartbeat $monitor
                if ($control.Stop) { break }
                [Threading.Thread]::Sleep(100)
            }
        } catch {
            $control.Failure = $true
            [Console]::Error.WriteLine('Workflow progress monitoring failed. Check diagnostics directory access and any concurrent workflow.')
            if ($lock -and $monitor) {
                try {
                    Update-AkriProgressMessage $monitor @{
                        Kind = 'failed'; AtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                        Data = @{ Activity = 'Progress monitoring failed; orchestration is stopping. Resume with the existing state after repairing the diagnostic error.' }
                    }
                } catch {
                    [Console]::Error.WriteLine('Could not publish terminal monitor diagnostics; the failed orchestrator state remains authoritative.')
                }
            }
            throw
        } finally {
            if ($lock) { $lock.Dispose() }
            $control.Ready.Set()
        }
    }).AddArgument($PSCommandPath).AddArgument($control).AddArgument($options)
    $handle = $runner.BeginInvoke()
    $session = @{ Control = $control; Runner = $runner; Handle = $handle; Directory = $Directory; RunId = $RunId; Stopped = $false }
    $started = $false
    try {
        while (-not $control.Ready.Wait(100)) {
            if ($handle.IsCompleted) { break }
        }
        if ($control.Failure) { throw 'Workflow progress monitoring could not start.' }
        $started = $true
        return $session
    } finally {
        if (-not $started) { Stop-AkriProgressMonitor $session }
    }
}

function Test-AkriProgressMonitor {
    param([object]$Session)
    if ($Session.Control.Failure -or $Session.Handle.IsCompleted) {
        $Session.Control.Failure = $true
        $error = [InvalidOperationException]::new('Workflow progress monitoring stopped unexpectedly; inspect the diagnostics and terminal error.')
        $error.Data['AkriFailureCode'] = 'progress-monitor-failed'
        $error.Data['AkriFailureMessage'] = 'Progress monitoring failed. Repair the diagnostic error and resume using the existing intake and state; accepted work is preserved.'
        throw $error
    }
}

function Send-AkriProgressMessage {
    param([object]$Session, [string]$Kind, [hashtable]$Data, [switch]$NoWait)

    Test-AkriProgressMonitor $Session
    if ($NoWait -and $Session.Control.Queue.Count -ge 64) {
        throw 'Worker progress reports exceeded the bounded queue capacity.'
    }
    $message = @{ Kind = $Kind; Data = $Data; AtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Acknowledged = [Threading.Tasks.TaskCompletionSource[bool]]::new([Threading.Tasks.TaskCreationOptions]::RunContinuationsAsynchronously) }
    $Session.Control.Queue.Enqueue($message)
    if (-not $NoWait) {
        while (-not $message.Acknowledged.Task.Wait(100)) { Test-AkriProgressMonitor $Session }
        Test-AkriProgressMonitor $Session
    }
}

function Stop-AkriProgressMonitor {
    param([object]$Session)

    if ($Session.Stopped) { return }
    $Session.Control.Stop = $true
    try { $null = $Session.Runner.EndInvoke($Session.Handle) } finally {
        $Session.Runner.Dispose()
        $Session.Control.Ready.Dispose()
        $Session.Stopped = $true
    }
}

# SIG # Begin signature block
# MIInOgYJKoZIhvcNAQcCoIInKzCCJycCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDL3cuTJguqJwU4
# yNCHGxJbgvrQIW78ut0sjFvLzKDLu6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIL6w5xyBqeIV5U4YhLKB/S9WAX0V
# mBd9PXmjf8nSKYDaMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAZ/dpUCE87zvqWGjvg49Du+/OsrxydEv3ghGB0OIdnUQhnlu+NZOBIgTuIq5E
# bXDmrpF5BxuVluZVMU2QzZD7JFOD5PQgII0mJjVssS0HpaMi+3kc8R+++4bfbTBw
# PxORkT5RObQwR1EWvkOVVBi/eZ4joXj1rA8Iy/hXku7dldWh/WG7JpFA2cR8+jrD
# CxP4UVsZDbNuTZ2rLeErT+wcAU33wqTPlUfnbYl86GRSA2JU8sg+dVHGPSQXqXsz
# f/rh529KcacJLB+S//zdcR1Z6E9RLjqKo5NOQAT4JeQgZDXklqLuhGGaAY6LyFcv
# A684trVgh0zVgKESMLo77RD+AqGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38G
# CSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCB69tANhTm/kGfRQRchenqt9KzVSly8hr3jcvIei6wS5gIGaqpviH1QGBMy
# MDI2MTEwNTIxNTkyNS4wNjdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHt
# MIIHIDCCBQigAwIBAgITMwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJa
# Fw0yNzA1MTcxOTQwMDJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC//w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjc
# rIlOSzpJc4ZeUxEyli6x6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojy
# vN43SEGWqSfVc3I3BlsYT35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4
# p+9/lyJjD+ULs3YXBhVrfZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/n
# SsmG2P1zv/cv4gSoMBnWeQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxO
# DlkfiyHk9Mkk/TrYTjmjPCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8
# OSt835rBzDprrcAhwmgfhoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9N
# q/GwbfgqKqGmc9xhKuRFcjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5
# CyhNqXYYE/z0pcXdYaNIkQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgm
# A9oSS0EfvFRMWPA/gpSvF3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaq
# GRxrB+2r/7B3X81Tps99KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+A
# rVPlz3w4tqjcTNm1dt3tTua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3Q
# L6aRkXHnJUn8y9iftB/Py22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJih
# diYpK8cPHFlqZOAiot0+GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZ
# lDquskeyuq01DTv91N4qM8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3
# u1Zh3+S3tjQdqN+dyw60RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1P
# f6def2pqfl3wFc++hkF8DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPy
# nGeE5OtvNoK1pkLsm/i8F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoD
# J4B5mEAS9aT2SKqllLeybOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9
# JsrkhhsKmb11ujqwgJyNx92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmj
# xeqBS4uU5rQeiAnVgpJeaVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQ
# DZoaZTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIIC
# OAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMx
# Ftkqr7XMXdsRyWU0lSKHZ6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7pd4hjAiGA8yMDI2MTEwNTIxNDk1OFoY
# DzIwMjYxMTA2MjE0OTU4WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDul3iGAgEA
# MAoCAQACAg9BAgH/MAcCAQACAhKGMAoCBQDumMoGAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAMW/0d+fg6DlxIlKzXgAMB7+y06aCtHWm6+YzPO8fvxH4MLu
# aLGw2pz/+mhZAbmTSJMnimx0Pb+MWEsiLXW3RJsydCZtlQtwS/CuGefkh3RxvVdi
# zxmOzGxzU40T1rq8ac9TvPF7ACCrurl6DAvSa7uIrLGiZGfp49+T6nL/JjXXgl6r
# H55Dcr9lyfga+i8C0iNVESEw1a4q+YxWzrnUBKMNqyyj/JsTt9T1nDjRV2hrRqLz
# xVyP/5k81F2A95Y9ZzlmNn6lhLqXGUPIHl66Hvj1x3kvHea+Ol/QPmffrB0ChGU9
# QHDsbprihl84OjpUiA9cbeVKCFoEkJS7vlkgpbsxggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCAv4JMDavMaNCiE5YUvLfNqQNVE2F2HZyi/NhfjzkFT6jCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaN
# P3VBYqLFjUsFnbgqMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAImNbQ+Z0OT9h8AAQAAAiYwIgQg5uCw81wtxxiMbY1GV49E6uCTmn6v
# Bu5gBlaLh+MeLDQwDQYJKoZIhvcNAQELBQAEggIAcvJjWnI2O3MVZAIyY8vcNktO
# kOrIzU5BMwQVPmxwWUAw6calk1HGR/E62j6dmuaYo69MiRjYgznZXH74SxcSkwjI
# 7JS3B7QnjBrICHCsBSYKqQaR36YgrGBC4Yltsk402WpQ2L+B5OHCBdrQnE7EX387
# PHDDExVwBskDH6VkcoSYZmIuR9YAYb0KgjUet6uNM7ttevL4dnnX4PnGdSZv7BSq
# 1GJoSFZNeXar8FpIWdcbN/tYQ9T7+excKQcmP2aIQQBYJlu9ZFNUVClNGvhvIEfM
# cTXXNIJJ7sLMXuu85xmDiBTAZoWW/IrFw+t+mnkzOyoyoxhYN2JWUr2T/IgG1cZ/
# +Akl/IHAQzwXIVbQDzBB6kPH89P88X7BJOLSOoQLVyGbT7wyjEqMHmomXQIehmL1
# 0+QTvkzcY1tsHG/Ddwn5ym2ao4QzeKeMzxSJpb9+bHkGlY/6psa1BLdcHLAk/eoL
# 1kOJx4cFr2zRw/QOXoi68GjphfctkGnm/9aPxgseTJtVNY/zb+0hnImZQiobdITI
# ktb/TC69iHlTkZHvMAnx8aj0cKGnGxcViJCIcDqbXF7N3dG8vvSrvdvmrEjLn7A+
# 5A7I5brqiwRDRcVl171WsB58nwa04L1oN8Zmaqm/vrXSblm2Zd7PXIN6d9GC+vN7
# e7EolejPD9T7Cr0ZQMk=
# SIG # End signature block
