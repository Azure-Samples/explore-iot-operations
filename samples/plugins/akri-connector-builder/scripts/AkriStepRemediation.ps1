#requires -Version 7.0

$script:findingProtectedDocumentPaths = $null

function Stop-AkriFailureEvidence {
    param([string]$Check, [string]$Location)

    $exception = [InvalidOperationException]::new("Failure evidence rejected [$Check] at $Location.")
    $exception.Data['AkriEvidenceCheck'] = $Check
    $exception.Data['AkriEvidenceLocation'] = $Location
    throw $exception
}

function Get-AkriRepairSourceFingerprint {
    $source = if (Test-Path -LiteralPath $WorkspacePath -PathType Container) { Get-CoreImplementationFingerprint } else { '' }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$source))).ToLowerInvariant()
}

function Get-AkriFindingReference {
    param([object]$Reference, [switch]$HostReport, [string]$Location = 'evidence')

    if (-not $Reference -or [string]$Reference.PSObject.Properties['sha256']?.Value -cnotmatch '^[a-f0-9]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Reference.PSObject.Properties['path']?.Value)) {
        Stop-AkriFailureEvidence 'reference-shape' $Location
    }
    $path = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathFullyQualified($Reference.path)) {
        $Reference.path
    } else { Join-Path $WorkspacePath $Reference.path }))
    if ([IO.Path]::GetRelativePath($gitRoot, $path).Contains(':')) { Stop-AkriFailureEvidence 'reference-stream' $Location }
    if ($path.Replace('\', '/').EndsWith('/.spec/grounding-index.json', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-AkriFailureEvidence 'reference-protected-index' $Location
    }
    if ($HostReport) {
        if (-not $path.StartsWith("$StatePath.", [StringComparison]::Ordinal)) { Stop-AkriFailureEvidence 'reference-host-ownership' $Location }
    } elseif (-not (Test-PathWithinRoot $path $WorkspacePath)) { Stop-AkriFailureEvidence 'reference-outside-workspace' $Location }
    try { Assert-AkriProgressDirectory $path $gitRoot } catch { Stop-AkriFailureEvidence 'reference-link-or-root' $Location }
    if ($null -eq $script:findingProtectedDocumentPaths) {
        # Input registration is fixed for this launcher; do not rehash large documents per finding.
        $script:findingProtectedDocumentPaths = @(Get-AkriDeclaredDocuments -IntakePath $IntakePath -RepositoryRoot $gitRoot |
            ForEach-Object fullPath)
    }
    if ($path -in $script:findingProtectedDocumentPaths) { Stop-AkriFailureEvidence 'reference-protected-document' $Location }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-AkriFailureEvidence 'reference-missing-file' $Location }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Length -eq 0 -or $item.Length -gt 4MB) { Stop-AkriFailureEvidence 'reference-size' $Location }
    if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Reference.sha256) {
        Stop-AkriFailureEvidence 'reference-hash-mismatch' $Location
    }
    return [pscustomobject]@{ path = $path; sha256 = [string]$Reference.sha256 }
}

function Test-AkriRepairFindings {
    param([object[]]$Findings, [string]$Location = 'findings')

    if ($Findings.Count -lt 1 -or $Findings.Count -gt 100) { Stop-AkriFailureEvidence 'findings-count' $Location }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $Findings.Count; $index++) {
        $finding = $Findings[$index]
        if (-not $finding -or @('id', 'code', 'message', 'evidence').Where({ -not $finding.PSObject.Properties[$_] }).Count) {
            Stop-AkriFailureEvidence 'finding-shape' "$Location[$index]"
        }
        if ([string]$finding.id -cnotmatch '^[A-Za-z0-9_.:-]{1,80}$' -or -not $ids.Add([string]$finding.id) -or
            [string]$finding.code -cnotmatch '^[a-z][a-z0-9-]{0,79}$' -or
            [string]::IsNullOrWhiteSpace([string]$finding.message) -or $finding.message.Length -gt 240 -or
            (Protect-CredentialText $finding.message).Count -or
            @($finding.evidence).Count -lt 1 -or @($finding.evidence).Count -gt 8) {
            Stop-AkriFailureEvidence 'finding-shape' "$Location[$index]"
        }
        for ($referenceIndex = 0; $referenceIndex -lt @($finding.evidence).Count; $referenceIndex++) {
            $null = Get-AkriFindingReference $finding.evidence[$referenceIndex] -Location "$Location[$index].evidence[$referenceIndex]"
        }
    }
}

function Test-AkriWorkerFailureEvidence {
    param([object]$Failure)

    $location = 'failure'
    try {
        if (-not $Failure -or @('code', 'classification', 'message', 'evidence').Where({ -not $Failure.PSObject.Properties[$_] }).Count) {
            Stop-AkriFailureEvidence 'failure-envelope' $location
        }
        if ([string]$Failure.code -cnotmatch '^[a-z][a-z0-9-]{0,79}$' -or
            $Failure.classification -cnotin @('implementation', 'review', 'prerequisite', 'tool', 'budget', 'user-decision', 'cancelled') -or
            [string]::IsNullOrWhiteSpace([string]$Failure.message) -or $Failure.message.Length -gt 240 -or
            (Protect-CredentialText $Failure.message).Count -or
            @($Failure.evidence).Count -gt 8) { Stop-AkriFailureEvidence 'failure-envelope' $location }
        $repairable = $Failure.code -cin $workflowConfiguration.execution.remediation.repairableCodes
        if ($repairable -and $Failure.classification -cne $(if ($Failure.code -eq 'review-changes-required') { 'review' } else { 'implementation' })) {
            Stop-AkriFailureEvidence 'failure-classification' $location
        }
        $references = @()
        for ($index = 0; $index -lt @($Failure.evidence).Count; $index++) {
            $location = "failure.evidence[$index]"
            $reference = Get-AkriFindingReference $Failure.evidence[$index] -Location $location
            $references += $reference
            $text = Get-Content -LiteralPath $reference.path -Raw
            if ((Protect-CredentialText $text).Count) { Stop-AkriFailureEvidence 'report-credentials' $location }
            if (-not $repairable) { continue }
            $matches = [regex]::Matches($text, '(?m)^AKRI_REVIEW_RESULT=(\{[^\r\n]+\})\r?$')
            if ($matches.Count -ne 1) { Stop-AkriFailureEvidence 'report-verdict-count' $location }
            try { $report = $matches[0].Groups[1].Value | ConvertFrom-Json } catch {
                Stop-AkriFailureEvidence 'report-json' $location
            }
            $current = & (Join-Path $PSScriptRoot 'Get-AkriVerificationFingerprint.ps1') -WorkspacePath $WorkspacePath -ProductionOnly
            if ($report.status -cne 'changes-required' -or $report.scope -cne 'full') {
                Stop-AkriFailureEvidence 'report-negative-full-review' $location
            }
            if ($report.productionFingerprint -cne $current) { Stop-AkriFailureEvidence 'report-production-fingerprint' $location }
            Test-AkriRepairFindings @($report.findings) -Location "$location.findings"
            for ($findingIndex = 0; $findingIndex -lt @($report.findings).Count; $findingIndex++) {
                if ($report.findings[$findingIndex].code -cnotin $workflowConfiguration.execution.remediation.repairableCodes) {
                    Stop-AkriFailureEvidence 'finding-code-not-repairable' "$location.findings[$findingIndex].code"
                }
            }
        }
        if ($repairable -and -not $references.Count) { Stop-AkriFailureEvidence 'failure-evidence-required' $location }
        return [pscustomobject]@{ References = $references; Repairable = $repairable }
    } catch {
        if ($_.Exception.Data.Contains('AkriEvidenceCheck')) { throw }
        Stop-AkriFailureEvidence 'evidence-shape-or-read' $location
    }
}

function Register-AkriWorkerReviewPasses {
    param([object]$Step, [object]$State, [object[]]$Passes)

    if ($Passes.Count -gt $workflowConfiguration.execution.reviewPassLimit) {
        Stop-StepFailure -Code 'review-budget-exhausted' -Classification 'budget' `
            -Message 'Worker review history exceeds the configured budget. Preserve the original reports and counters; no automatic repair was authorized.'
    }
    for ($passIndex = 0; $passIndex -lt $Passes.Count; $passIndex++) {
        $pass = $Passes[$passIndex]
        $location = "review.passes[$passIndex]"
        if (-not $pass -or -not $pass.PSObject.Properties['evidence'] -or
            @($pass.evidence).Count -lt 1 -or @($pass.evidence).Count -gt 8) {
            Stop-AkriFailureEvidence 'review-history-reference-count' $location
        }
        $references = @()
        for ($index = 0; $index -lt @($pass.evidence).Count; $index++) {
            $references += Get-AkriFindingReference $pass.evidence[$index] -Location "$location.evidence[$index]"
        }
        $identity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($references.sha256 | Sort-Object -Unique) -join ','))).ToLowerInvariant()
        if (@($State.WorkerReviewReports | Where-Object { $_.StepId -ceq $Step.Id -and $_.Sha256 -ceq $identity }).Count) { continue }
        $retained = @()
        foreach ($reference in $references) {
            $text = Get-Content -LiteralPath $reference.path -Raw
            $verdicts = [regex]::Matches($text, '(?m)^AKRI_REVIEW_RESULT=(\{[^\r\n]+\})\r?$')
            if ($verdicts.Count -ne 1) { Stop-AkriFailureEvidence 'review-history-verdict-count' $location }
            if ((Protect-CredentialText $text).Count) { Stop-AkriFailureEvidence 'review-history-credentials' $location }
            try { $verdict = $verdicts[0].Groups[1].Value | ConvertFrom-Json } catch {
                Stop-AkriFailureEvidence 'review-history-json' $location
            }
            if (-not $verdict -or @('scope', 'status', 'productionFingerprint').Where({ -not $verdict.PSObject.Properties[$_] }).Count) {
                Stop-AkriFailureEvidence 'review-history-verdict' $location
            }
            if ($verdict.scope -cne 'full' -or $verdict.status -cnotin @('passed', 'changes-required') -or
                $verdict.productionFingerprint -cnotmatch '^[a-f0-9]{64}$') {
                Stop-AkriFailureEvidence 'review-history-verdict' $location
            }
            $path = "$StatePath.$($Step.Id).$([guid]::NewGuid().ToString('N')).worker-review.txt"
            Copy-Item -LiteralPath $reference.path -Destination $path
            $retained += [pscustomobject]@{ path = $path; sha256 = $reference.sha256; originalPath = $reference.path }
        }
        $State.WorkerReviewReports = @($State.WorkerReviewReports) + [pscustomobject]@{
            StepId = $Step.Id; Sha256 = $identity; Evidence = $retained
        }
        Save-OrchestratorState $State
    }
}

function Assert-AkriStepReviewBudget {
    param([object]$Step, [object]$State)

    $workerReviews = @($State.WorkerReviewReports | Where-Object StepId -CEQ $Step.Id)
    if ($workerReviews.Count -ge $workflowConfiguration.execution.reviewPassLimit) {
        Stop-StepFailure -Code 'review-budget-exhausted' -Classification 'budget' `
            -Evidence @($workerReviews | Select-Object -Last 1 | ForEach-Object Evidence) `
            -Message 'The persisted same-step review budget is exhausted. Retain original reports and controls; no worker or review was restarted.'
    }
}

function Stop-AkriWorkerFailure {
    param([object]$Step, [object]$Receipt, [object]$State)

    # Retain only bounded, non-secret routing and validated references, never raw worker output.
    $failure = $Receipt.PSObject.Properties['failure']?.Value ?? [pscustomobject]@{}
    $observed = @()
    foreach ($reference in @($failure.PSObject.Properties['evidence']?.Value | Select-Object -First 8)) {
        try {
            $validated = Get-AkriFindingReference $reference
            if (-not (Protect-CredentialText $validated.path).Count) { $observed += $validated }
        } catch { }
    }
    $claimedCode = [string]$failure.PSObject.Properties['code']?.Value
    $claimedClassification = [string]$failure.PSObject.Properties['classification']?.Value
    $receiptPath = "$StatePath.$($Step.Id).$([guid]::NewGuid().ToString('N')).worker-receipt.json"
    Write-AkriAtomicJson $receiptPath ([pscustomobject]@{
        stepId = $Step.Id; status = $Receipt.status; workerModel = $Receipt.workerModel; workerReasoning = $Receipt.workerReasoning
        failure = @{
            code = $(if ($claimedCode -cmatch '^[a-z][a-z0-9-]{0,79}$' -and -not (Protect-CredentialText $claimedCode).Count) { $claimedCode } else { '[invalid]' })
            classification = $(if ($claimedClassification -cin @('implementation', 'review', 'prerequisite', 'tool', 'budget', 'user-decision', 'cancelled')) { $claimedClassification } else { '[invalid]' })
            evidence = $observed
        }
        projection = 'Messages, unknown fields and invalid references omitted.'
        receiptSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 32 -Compress)))).ToLowerInvariant()
    })
    $references = @()
    try {
        # Charge observed original reviews even when the final failure envelope is rejected.
        $validated = Test-AkriWorkerFailureEvidence $failure
        foreach ($reference in $validated.References) {
            $retained = "$StatePath.$($Step.Id).$([guid]::NewGuid().ToString('N')).findings.txt"
            Copy-Item -LiteralPath $reference.path -Destination $retained
            $references += [pscustomobject]@{ path = $retained; sha256 = $reference.sha256; originalPath = $reference.path }
        }
        if ($validated.Repairable) {
            Register-AkriWorkerReviewPasses $Step $State @([pscustomobject]@{ evidence = $validated.References })
        }
        $message = ConvertTo-AkriProgressText $failure.message
    } catch {
        if ($_.Exception.Data['AkriFailureCode'] -eq 'review-budget-exhausted') {
            $_.Exception.Data['AkriFailureEvidence'] = $references
            $_.Exception.Data['AkriFailureReceiptPath'] = $receiptPath
            throw
        }
        $check = [string]$_.Exception.Data['AkriEvidenceCheck']
        $location = [string]$_.Exception.Data['AkriEvidenceLocation']
        if (-not $check) { $check = 'review-history-or-retention'; $location = 'failure' }
        Stop-StepFailure -Code 'receipt-failure-invalid' -ReceiptPath $receiptPath `
            -Diagnostic ([pscustomobject]@{ Check = $check; Location = $location }) `
            -Message "Non-passing receipt rejected [$check] at $location. No automatic repair was authorized."
    }
    Stop-StepFailure -Code $failure.code -Message $message -Classification $failure.classification -Evidence $references -ReceiptPath $receiptPath
}

function Invoke-WorkflowStep {
    param([object]$Step, [object]$State)

    $script:stepDeadline = $null
    $activeRepair = $null
    Assert-AkriStepReviewBudget $Step $State
    $records = @($State.RemediationAttempts | Where-Object StepId -CEQ $Step.Id)
    $source = Get-AkriRepairSourceFingerprint
    $failedSource = if ($State.LastFailure -and $State.LastFailure.StepId -ceq $Step.Id) {
        [string]$State.LastFailure.PSObject.Properties['SourceFingerprint']?.Value
    } else { '' }
    if ($failedSource -cnotmatch '^[a-f0-9]{64}$' -and $records.Count) {
        $failedSource = $records[-1].ResultSourceFingerprint
    }
    $manuallyRepaired = $records.Count -and ($records[-1].ResultSourceFingerprint -cne $source -or
        $records[-1].SourceFingerprint -cne $records[-1].ResultSourceFingerprint)
    if ($records.Count -and $State.LastFailure -and $State.LastFailure.StepId -eq $Step.Id -and
        $State.LastFailure.Code -cin (@($workflowConfiguration.execution.remediation.repairableCodes) +
            @('remediation-budget-exhausted', 'remediation-unchanged', 'review-budget-exhausted', 'worker-timeout')) -and
        $records[-1].Status -ne 'passed' -and $failedSource -ceq $source) {
        Stop-StepFailure -Code $(if ($records.Count -ge $workflowConfiguration.execution.remediation.maximumAttemptsPerStep) {
            'remediation-budget-exhausted'
        } else { 'remediation-unchanged' }) -Classification 'budget' -Evidence @($records[-1].Evidence) -SourceFingerprint $source `
            -Message 'Automatic repair of this unchanged failed revision is stopped. Retain all findings and retry controls; repair source/tests in place before resuming the same state.'
    }
    try {
        while ($true) {
            try {
                $result = Invoke-WorkflowStepAttempt $Step $State -VerifyRepairedSource:$manuallyRepaired
                $manuallyRepaired = $false
                if ($activeRepair) {
                    $activeRepair.Status = 'passed'
                    $activeRepair.ResultSourceFingerprint = Get-AkriRepairSourceFingerprint
                    Save-OrchestratorState $State
                }
                return $result
            } catch {
                if ($activeRepair) {
                    $activeRepair.Status = 'failed'
                    $activeRepair.ResultSourceFingerprint = Get-AkriRepairSourceFingerprint
                    Save-OrchestratorState $State
                }
                $code = [string]$_.Exception.Data['AkriFailureCode']
                $classification = [string]$_.Exception.Data['AkriFailureClassification']
                $evidence = @($_.Exception.Data['AkriFailureEvidence'] | Where-Object { $null -ne $_ })
                $failure = [pscustomobject]@{
                    StepId = $Step.Id; Code = $code
                    Message = [string]$_.Exception.Data['AkriFailureMessage']
                    Classification = $classification; Evidence = $evidence
                    Diagnostic = $_.Exception.Data['AkriFailureDiagnostic']
                    ReceiptPath = $_.Exception.Data['AkriFailureReceiptPath']
                    SourceFingerprint = Get-AkriRepairSourceFingerprint
                    Progress = $_.Exception.Data['AkriFailureProgress']
                }
                $_.Exception.Data['AkriFailureSourceFingerprint'] = $failure.SourceFingerprint
                if (-not $code) {
                    $failure.Code = 'step-execution-failed'
                    $failure.Message = 'Step execution failed; inspect retained diagnostics and resume the same state after repair.'
                }
                $failurePath = "$StatePath.$($Step.Id).$([guid]::NewGuid().ToString('N')).failure.json"
                Write-AkriAtomicJson $failurePath $failure
                $State.FailureHistory = @($State.FailureHistory) + [pscustomobject]@{
                    StepId = $Step.Id; Code = $failure.Code; Path = $failurePath
                }
                Save-OrchestratorState $State
                if ($classification -cnotin @('implementation', 'review') -or
                    $code -cnotin $workflowConfiguration.execution.remediation.repairableCodes -or -not $evidence.Count) { throw }
                foreach ($reference in $evidence) { $null = Get-AkriFindingReference $reference -HostReport }
                Assert-AkriStepReviewBudget $Step $State
                $source = Get-AkriRepairSourceFingerprint
                $records = @($State.RemediationAttempts | Where-Object StepId -CEQ $Step.Id)
                if ($records.Count -ge $workflowConfiguration.execution.remediation.maximumAttemptsPerStep) {
                    Stop-StepFailure -Code 'remediation-budget-exhausted' -Classification 'budget' -Evidence $evidence `
                        -Message "Step '$($Step.Id)' exhausted its persisted host repair budget. Retain findings, repair source/tests in place and resume; never clear attempts."
                }
                if (@($records | Where-Object SourceFingerprint -CEQ $source).Count) {
                    Stop-StepFailure -Code 'remediation-unchanged' -Evidence $evidence `
                        -Message 'The repair returned the same failure without a source/test change. No unchanged collection or review will be repeated.'
                }
                if ($script:stepDeadline -and [DateTimeOffset]::UtcNow -ge $script:stepDeadline) {
                    Stop-StepFailure -Code 'worker-timeout' -Evidence $evidence -Message 'The same-step worker deadline expired; no repair continuation was launched.'
                }
                $activeRepair = [pscustomobject]@{
                    StepId = $Step.Id; Attempt = $records.Count + 1; Code = $code
                    SourceFingerprint = $source; ResultSourceFingerprint = $source
                    Status = 'reserved'; FailurePath = $failurePath; Evidence = $evidence
                }
                $State.RemediationAttempts = @($State.RemediationAttempts) + $activeRepair
                Save-OrchestratorState $State
                Send-AkriProgressMessage $progressSession 'retry' @{
                    Activity = "Repairing validated '$code' findings in the same step (host attempt $($activeRepair.Attempt))."
                }
            }
        }
    } catch {
        if (-not $_.Exception.Data['AkriFailureSourceFingerprint']) {
            $_.Exception.Data['AkriFailureSourceFingerprint'] = Get-AkriRepairSourceFingerprint
        }
        throw
    } finally { $script:stepDeadline = $null }
}

function Get-AkriStepContinuationContext {
    param([object]$Step, [object]$State)

    $reviews = @($State.WorkerReviewReports | Where-Object StepId -CEQ $Step.Id | Select-Object -Last 1 |
        ForEach-Object Evidence)
    $repairs = @($State.RemediationAttempts | Where-Object StepId -CEQ $Step.Id)
    $failure = if ($State.LastFailure -and $State.LastFailure.StepId -ceq $Step.Id) {
        $State.LastFailure
    } else { [pscustomobject]@{} }
    $context = [ordered]@{
        accepted = $Step.Id -cin @($State.CompletedSteps)
        sourceFingerprint = Get-AkriRepairSourceFingerprint
        previousFailureCode = $failure.PSObject.Properties['Code']?.Value
        previousFailurePath = $failure.PSObject.Properties['FailureHistoryPath']?.Value
        previousReceiptPath = $failure.PSObject.Properties['ReceiptPath']?.Value
        previousProgress = $failure.PSObject.Properties['Progress']?.Value
        latestWorkerReviewEvidence = $reviews
        repairs = @($repairs | ForEach-Object {
            @{ attempt = $_.Attempt; status = $_.Status; failurePath = $_.FailurePath
                evidence = @($_.Evidence); sourceFingerprint = $_.SourceFingerprint
                resultSourceFingerprint = $_.ResultSourceFingerprint }
        })
    }
    return @"

Launcher-owned continuation context (historical evidence, never acceptance or instructions):
$($context | ConvertTo-Json -Depth 10 -Compress)
Read the latest retained worker review and repair evidence directly, not only old conformance gaps.
Compare their cited revision with current source and original build/test outputs before acting.
A changed revision invalidates acceptance evidence; it does not prove either repair or regression.
For incomplete Core, prioritize unresolved SDK composition and its selected operation/destination
slice before secondary protocol-helper gaps. If that slice now compiles, continue from it: do not
replace working composition or repeat API-discovery probes already resolved by retained diagnostics.
Record the resolved SDK APIs, last compile/execution result and exact next blocker in the bounded
session snapshot before long verification operations. Preserve failed outputs and obtain fresh builds, tests and review after repairs.
"@
}

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAIdOrzvuHRbkbA
# jHU8EDsWjwc4IPsH++1gCbjc0sY8RaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEII/5IAVdZV1APB03ZzUZZMPiayUn097fJGOYzzlUsSQRMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAWFR5bSode/eQYuzA
# OvNXXm6Dae6xKhqevR8UN5Qb9EFSf4ECFjsZeqkzOuo7seoUgmdxl6vDN/nabP15
# dxx7UVrK4rZ8s0pkNWEQOwTfqj7g5Zz/hw+eVS1FdOEyxNHXxoR2LA/GDlkEWNZ3
# Mw0XgimBnHnWuiaEDA0gvN6TI9AIeUMu5AXLrGNwk2Yu8PIKhiWrVizNSeiS3v6M
# XWeQw06yGtWRvCoQPjbFKi8Xy9KF4YSF/GFCLNf1vjYTgJ1Xy8+7He9+esy68+xt
# Eo8Is+GfWg47lIws8Si0z6PbBn5yqVR+04DEgsU6Wtb+CZQco/i4nFyqcPUXjZiu
# 4ddS4qGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBQ5lnLADVmlYij
# LyBD7nwWPfB9dzaVflJqIlemDF04ywIGatlN2uX+GBMyMDI2MTEwNTIxNTkxOS4y
# OTlaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiQ7hCGwLKxkIgABAAACJDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTla
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj
# 6W3UaQ2Zr4hNvSy7j7UMPFVys7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrL
# QCOZcgLvz6FkqmghzQxzmkgKtLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcV
# iBX4LcHk38RusZiF7wxSa5t/Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9
# pU9uriGdDxfJXn/lc49CxbXqA3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfd
# rA29sWTSNKig9CtBC5tzQj0flbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjl
# yUP9ZO38839NwSuiHtvsFCNkTNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PD
# ERyrAs0pvfUWOLapVQajHPoCnuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8W
# wBtk3Yxyhjj0GXw909i0EkTkVyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1Y
# GnYwCjIwa5/lMW0pFn/HpJdB6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v
# 3E9kwN9VBC+wJESBECC1gZMCS5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3
# SNt0a0Q5Nc2Ul+rMlQxXoP9isXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFHMfkX1u/zJLCMe0gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA+wHSbmhIpM8CRVZ4tk624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko
# 6diEDHXPNWvAagxastCewPzm5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/
# Fwps1sbNUEu7Bzg004qULIVJ963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQT
# HZgwuNB6QhcEEsgogLVwNRj37VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi
# 6jlcfqfo619uDH9r8k2qAOHCeEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilU
# Son07wjHu0e0ssBmtBafPb4Gd+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oc
# zxC/4JT3Hf45JEtszToXwNskV3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGE
# lPl5GRoPtJiDEvRIbv5MFKIw2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOk
# X4ug0/0mN2CSarhuSi9NmHIOpUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1o
# bjAGKdWMPCrlSyNAs0jZYzkha535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbU
# VqMU1OrQbHfdyzJpbhJC1PbAZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMC
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
# U1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+
# 46CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7pbonTAiGA8yMDI2MTEwNTExMzU1N1oYDzIwMjYxMTA2MTEzNTU3
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuluidAgEAMAoCAQACAh7lAgH/MAcC
# AQACAhKsMAoCBQDumDodAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABxH
# O5kOOP6g8IYrrjCr///01OFuUh2eyATAM+o+CUdR304U2cB9zheI3XZtKJayPJ/8
# VVFt15S94YrsE7sOhaN1Won7yKBUXLDnwjsDQjAOy46A9wD7WsVMAYa5MzG2Z6FA
# 0/kEWZy5FAI27qt77ox/A+00pmtbfPgrQYq1nwnKjIAuIbtr7XbbT7npEH4tYSw2
# ifvJ+XSGsONBdMSmd91dlHOU1CW4521g/pQtsOj2cxtvIuBbXdVJ3GJpe72YTwTW
# 0fxtYAjUyQl81X1F+Gb3ItqxNQANatgmwDiUq1HtFN31Bfxl7Mb1n3AhCcsXX0t5
# wK6APERW3iQKDOd7gtgxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiQ7hCGwLKxkIgABAAACJDANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDj
# ihntCtYsAUrOVH+4Qa8f1/Grhh4fMCSSbaV2LADe/TCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIEghPTdqm/dRyZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCys
# ZCIAAQAAAiQwIgQgUwE/ddsiC7NBYwZm28PA9IRZFM1cxXO1NQFS04plfOUwDQYJ
# KoZIhvcNAQELBQAEggIARcG+xhm2LAI+ywXHDH/Cu6XRURYimPDmWK8cG1LJuboy
# 2y8oUfvc1bZl8vIl6klO7ptcO1ODYRaeowcalRCmx805KIxlaDYlL/VvHR8ueUnR
# rI4EOv/+48ShDn1j1yP3L8eVQV7vAMk8n+4iif/ONyxXC/w1kKFrAArN1O3BlAT0
# JeR05WozsW6QrxHKlU7SV31A6W35SStYC/hflYqsO0sA/EFvcVUqnOJD9yfpUrja
# GflnirkVIDuX4PZnyyRI2ieJpIP+ftLofBg7euFDsMPrpsUu2JpLN8zwk7ZBSRtA
# VGmGV1CxOv+J9qHY4p1BXLrBQf1Nx4AY/56cTnI67yLxhxS6jPSqeMmE2dF/8H5X
# iNwaRMtPzz8VjWngP0Jt/EbwNkywIhD2Qx4CdYZPGTvXZvBdCcYfEeIPIjrNAkUU
# G+yfi4DX8o5dyhOk1rdRQ6y5QlRx3ia58QV2xYFPQ744qiiTTsopTfXx/pK4/Y4S
# eyJBGlhZZu9YrGuBJCwMBkAme1ztlMF6qZVm+4LIU2dDYHflplyh96hWBnfjEPjf
# FHZE09nGbnkzJurDgFre1a2MrVcvlx/f2QX64k3C2lbqDuaOE34dk+4cAa1UE8r8
# NvSplbNHBdENFGGYkYu1MEFL4HvVb3do8CtMFKXMRLMgrDi8DJ+NQennWivbX2Y=
# SIG # End signature block
