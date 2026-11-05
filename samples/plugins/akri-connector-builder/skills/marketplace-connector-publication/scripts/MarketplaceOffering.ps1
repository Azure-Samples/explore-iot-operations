#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConnectorRoot,

    [Parameter(Mandatory)]
    [string]$ConnectorName,

    [Parameter(Mandatory)]
    [string]$ApplicationName,

    [Parameter(Mandatory)]
    [string]$Publisher,

    [Parameter(Mandatory)]
    [string]$Description,

    [Parameter(Mandatory)]
    [string]$ChartVersion,

    [Parameter(Mandatory)]
    [string]$ApplicationVersion,

    [Parameter(Mandatory)]
    [string]$ManifestVersion,

    [Parameter(Mandatory)]
    [bool]$AutoUpgradeMinorVersion,

    [Parameter(Mandatory)]
    [string]$ConnectorRegistry,

    [Parameter(Mandatory)]
    [string]$ConnectorImage,

    [Parameter(Mandatory)]
    [ValidateSet('Tag', 'Digest')]
    [string]$ConnectorImageReferenceType,

    [Parameter(Mandatory)]
    [string]$ConnectorImageReference,

    [Parameter(Mandatory)]
    [bool]$PerCoreBilling,

    [string]$CpuRequest,

    [string]$MemoryRequest,

    [Parameter(Mandatory)]
    [string]$MetadataRegistry,

    [Parameter(Mandatory)]
    [string]$MetadataImage,

    [Parameter(Mandatory)]
    [string]$MetadataTag,

    [Parameter(Mandatory)]
    [ValidateCount(3, 5)]
    [string[]]$Keyword,

    [switch]$PublicRegistryAcknowledged,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-PatternValidationError {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($Value -cnotmatch $Pattern) {
        $Errors.Add("$Name is invalid: $Value")
    }
}

function Add-LengthValidationError {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($Value -ne $Value.Trim() -or $Value.Length -eq 0 -or $Value.Length -gt $Maximum) {
        $Errors.Add("$Name must be 1-$Maximum characters with no leading or trailing whitespace")
    }
}

function ConvertTo-YamlString {
    param([Parameter(Mandatory)][string]$Value)

    return ConvertTo-Json -InputObject $Value -Compress
}

function Assert-PathIsNotSymbolicLink {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to write through a symbolic link: $Path"
        }
    }
}

function Render-Template {
    param(
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Replacements
    )

    $placeholderPattern = '<[a-z][a-z0-9.-]*>'
    $templatePlaceholders = @(
        [regex]::Matches($Content, $placeholderPattern, 'IgnoreCase') |
            ForEach-Object Value |
            Sort-Object -Unique
    )
    $replacementPlaceholders = @($Replacements.Keys)
    $unexpectedPlaceholders = @($templatePlaceholders | Where-Object { -not $Replacements.Contains($_) })
    $unusedReplacements = @($replacementPlaceholders | Where-Object { $_ -notin $templatePlaceholders })

    if ($unexpectedPlaceholders.Count -gt 0) {
        throw "$TemplateName has unexpected placeholders: $($unexpectedPlaceholders -join ', ')"
    }
    if ($unusedReplacements.Count -gt 0) {
        throw "$TemplateName does not contain expected placeholders: $($unusedReplacements -join ', ')"
    }
    if ($templatePlaceholders.Count -eq 0) {
        return $Content
    }

    $replacementPattern = ($replacementPlaceholders | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
    return [regex]::Replace(
        $Content,
        $replacementPattern,
        [System.Text.RegularExpressions.MatchEvaluator] {
            param($match)
            return [string]$Replacements[$match.Value]
        }
    )
}

$dns1123Pattern = '^(?=.{1,63}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$'
$reverseDnsPattern = '^(?=.{3,253}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$'
$semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
$registryPattern = '^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::\d{1,5})?$'
$imagePattern = '^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$'
$tagPattern = '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
$digestPattern = '^sha256:[a-fA-F0-9]{64}$'
$cpuRequestPattern = '^(?:[1-9]\d*m|(?:[1-9]\d*(?:\.\d+)?|0\.\d*[1-9]\d*))$'
$memoryRequestPattern = '^(?:[1-9]\d*(?:\.\d+)?|0\.\d*[1-9]\d*)(?:[EPTGMK]i?|k)?$'
$keywordPattern = '^[A-Za-z0-9][A-Za-z0-9 _-]{0,49}$'
$applicationVersionPattern = '^[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$'

$validationErrors = [System.Collections.Generic.List[string]]::new()
if (-not $PublicRegistryAcknowledged) {
    $validationErrors.Add('public registry acknowledgment is required because Marketplace-copied images can be publicly accessible, including for private plans')
}
Add-PatternValidationError $validationErrors 'connector name' $ConnectorName $dns1123Pattern
Add-PatternValidationError $validationErrors 'application name' $ApplicationName $reverseDnsPattern
Add-LengthValidationError $validationErrors 'publisher' $Publisher 100
Add-LengthValidationError $validationErrors 'description' $Description 200
Add-PatternValidationError $validationErrors 'chart version' $ChartVersion $semverPattern
Add-PatternValidationError $validationErrors 'application version' $ApplicationVersion $applicationVersionPattern
Add-PatternValidationError $validationErrors 'manifest version' $ManifestVersion $semverPattern
Add-PatternValidationError $validationErrors 'connector registry' $ConnectorRegistry $registryPattern
Add-PatternValidationError $validationErrors 'connector image' $ConnectorImage $imagePattern
if ($ConnectorImageReferenceType -eq 'Tag') {
    Add-PatternValidationError $validationErrors 'connector image tag' $ConnectorImageReference $tagPattern
} else {
    Add-PatternValidationError $validationErrors 'connector image digest' $ConnectorImageReference $digestPattern
}
if ($PerCoreBilling -and [string]::IsNullOrWhiteSpace($CpuRequest)) {
    $validationErrors.Add('CPU request is required when per-core billing is selected')
}
if (-not [string]::IsNullOrEmpty($CpuRequest)) {
    Add-PatternValidationError $validationErrors 'CPU request' $CpuRequest $cpuRequestPattern
}
if (-not [string]::IsNullOrEmpty($MemoryRequest)) {
    Add-PatternValidationError $validationErrors 'memory request' $MemoryRequest $memoryRequestPattern
}
Add-PatternValidationError $validationErrors 'metadata registry' $MetadataRegistry $registryPattern
Add-PatternValidationError $validationErrors 'metadata image' $MetadataImage $imagePattern
Add-PatternValidationError $validationErrors 'metadata tag' $MetadataTag $tagPattern
foreach ($keywordValue in $Keyword) {
    Add-PatternValidationError $validationErrors 'keyword' $keywordValue $keywordPattern
}
if ($validationErrors.Count -gt 0) {
    throw $validationErrors -join [Environment]::NewLine
}

$templateDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'templates'))
if (-not (Test-Path -LiteralPath $templateDirectory -PathType Container)) {
    throw "Template directory not found: $templateDirectory"
}

if (-not [System.IO.Path]::IsPathFullyQualified($ConnectorRoot)) {
    throw 'ConnectorRoot must be the confirmed absolute connector workspace path'
}
$connectorRootPath = [System.IO.Path]::GetFullPath($ConnectorRoot)
$bundleRoot = Join-Path $connectorRootPath 'marketplace-bundle'
$chartRoot = Join-Path $bundleRoot "$ConnectorName-helm-chart"
foreach ($protectedPath in @(
        $connectorRootPath,
        $bundleRoot,
        $chartRoot,
        (Join-Path $chartRoot 'templates')
    )) {
    Assert-PathIsNotSymbolicLink $protectedPath
}
$resourceRequestLines = @()
if (-not [string]::IsNullOrEmpty($CpuRequest)) {
    $resourceRequestLines += "    cpu: $(ConvertTo-YamlString $CpuRequest)"
}
if (-not [string]::IsNullOrEmpty($MemoryRequest)) {
    $resourceRequestLines += "    memory: $(ConvertTo-YamlString $MemoryRequest)"
}
$resourcesValues = if ($resourceRequestLines.Count -gt 0) {
    "resources:`n  requests:`n$($resourceRequestLines -join "`n")"
} else {
    ''
}
$templateDefinitions = @(
    [pscustomobject]@{
        Template = 'Chart.yaml.template'
        Output = Join-Path $chartRoot 'Chart.yaml'
        Replacements = [ordered]@{
            '<connector-name>' = $ConnectorName
            '<connector-short-description-yaml>' = ConvertTo-YamlString $Description
            '<chart-version>' = $ChartVersion
            '<application-version-yaml>' = ConvertTo-YamlString $ApplicationVersion
            '<keywords-yaml>' = ($Keyword | ForEach-Object { "  - $(ConvertTo-YamlString $_)" }) -join "`n"
        }
    }
    [pscustomobject]@{
        Template = 'values.yaml.template'
        Output = Join-Path $chartRoot 'values.yaml'
        Replacements = [ordered]@{
            '<connector-name>' = $ConnectorName
            '<connector-registry-yaml>' = ConvertTo-YamlString $ConnectorRegistry
            '<connector-image-yaml>' = ConvertTo-YamlString $ConnectorImage
            '<connector-image-reference-type>' = $ConnectorImageReferenceType
            '<connector-image-reference-key>' = $ConnectorImageReferenceType.ToLowerInvariant()
            '<connector-image-reference-yaml>' = ConvertTo-YamlString $ConnectorImageReference
            '<metadata-registry-yaml>' = ConvertTo-YamlString $MetadataRegistry
            '<metadata-image-yaml>' = ConvertTo-YamlString $MetadataImage
            '<metadata-tag-yaml>' = ConvertTo-YamlString $MetadataTag
            '<resources-values-yaml>' = $resourcesValues
        }
    }
    [pscustomobject]@{
        Template = 'manifest.yaml.template'
        Output = Join-Path $bundleRoot 'manifest.yaml'
        Replacements = [ordered]@{
            '<connector-name>' = $ConnectorName
            '<application-name>' = $ApplicationName
            '<publisher-yaml>' = ConvertTo-YamlString $Publisher
            '<connector-short-description-yaml>' = ConvertTo-YamlString $Description
            '<manifest-version>' = $ManifestVersion
            '<registry-server-yaml>' = ConvertTo-YamlString $ConnectorRegistry
        }
    }
    [pscustomobject]@{
        Template = 'CreateUiDefinition.json.template'
        Output = Join-Path $bundleRoot 'CreateUiDefinition.json'
        Replacements = [ordered]@{ '<connector-name>' = $ConnectorName }
    }
    [pscustomobject]@{
        Template = 'mainTemplate.json.template'
        Output = Join-Path $bundleRoot 'mainTemplate.json'
        Replacements = [ordered]@{
            '<auto-upgrade-minor-version-json>' = ConvertTo-Json -InputObject $AutoUpgradeMinorVersion -Compress
        }
    }
    [pscustomobject]@{
        Template = 'aio-application-definition.yaml.template'
        Output = Join-Path $chartRoot 'templates' 'aio-application-definition.yaml'
        Replacements = [ordered]@{}
    }
    [pscustomobject]@{
        Template = 'README.md.template'
        Output = Join-Path $bundleRoot 'README.md'
        Replacements = [ordered]@{
            '<connector-name>' = $ConnectorName
            '<chart-version>' = $ChartVersion
            '<application-version>' = $ApplicationVersion
            '<manifest-version>' = $ManifestVersion
        }
    }
)

$renderedFiles = @($templateDefinitions | ForEach-Object {
    $definition = $_
    $templatePath = Join-Path $templateDirectory $definition.Template
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Template does not exist: $templatePath"
    }

    $content = Render-Template $definition.Template (Get-Content -LiteralPath $templatePath -Raw) $definition.Replacements

    [pscustomobject]@{ Output = $definition.Output; Content = $content }
})

$existingFiles = @($renderedFiles.Output | Where-Object { Test-Path -LiteralPath $_ })
if ($existingFiles.Count -gt 0 -and -not $Force) {
    throw "Refusing to overwrite generated files; pass -Force to replace them: $($existingFiles -join ', ')"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($renderedFile in $renderedFiles) {
    $outputDirectory = Split-Path -Parent $renderedFile.Output
    Assert-PathIsNotSymbolicLink $outputDirectory
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    Assert-PathIsNotSymbolicLink $outputDirectory
    Assert-PathIsNotSymbolicLink $renderedFile.Output
    [System.IO.File]::WriteAllText($renderedFile.Output, $renderedFile.Content, $utf8NoBom)
}

foreach ($jsonFile in @('CreateUiDefinition.json', 'mainTemplate.json')) {
    $null = Get-Content -LiteralPath (Join-Path $bundleRoot $jsonFile) -Raw | ConvertFrom-Json
}

[pscustomobject]@{
    bundleRoot = $bundleRoot
    files = @($renderedFiles.Output)
} | ConvertTo-Json -Depth 3

# SIG # Begin signature block
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBa1SkxRHsSsN2X
# gXP725ir7hvievbmF3+2ih1AW37JpKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEICtmR49TyVC417ubfsGrqEuUy52P/+6a75RoSQAzfhJbMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEABlgGwZMcTPUuK9hq
# VqR3cu1ZsY4MWaNbrm+VRV97vwZWXW1ac1Y1FGu6PyBQefaUEcJnw7IXMJTRfWbi
# bIgsRjQjxH7rOSacAx7p3owXGih4NR72FOPVZaINyKCM01PEyjeWqITi9k9Z7t1I
# r5HXg55ub1Y4JDnEqxjaE9YY4qKktZfbOdZZiIr/2NcvqeBKZx2/4QLxJuouse8t
# KD1fE6jBX9xf12SOgBCvk7oYddCPmsCHYGqwCjszUc3OrKPXno0YuPozcwf506/4
# LpwU4nVuEtxNsOAMtkuCVM5tTV3pIjBMhiuCtL5lb9I2tGjfuTZffOc4d2omZHiV
# 6PGUOaGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCuZiqMs1pHaLyi
# fe0reuHcc4BULIwDEq/IYQO0tGSxygIGauvdmHjRGBMyMDI2MTEwNTIxNTgwMS4y
# NTRaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACMxBftzbaqEBSAAEAAAIzMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MTAxNTE4Mzc0MFoXDTI4MDEx
# MTE4Mzc0MFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAvJeYUpkXCzUl9TgLYm5Z20zo1Yt1XXD87sEzAs5mcGBr
# 6rM3uo4i5fMAfljkijJfwY3ypfnBuPX8IYS/SKq5k3q0Z2BzrVzMLMLTA81OPNgU
# /HspMj9wd/AxEuz7A0wH5vivLQWOribIaX5Efp4OFt3vS1FS2bDNL8ojhv1v+yVK
# RX0WAmcN1j1lGKl/7qgPd2fJnQJAbMVS6NjAW16l7gLJYrFET/D9glQNAt0ZoNvt
# NhWQH3TxoOvtHl3VVFZpbpdbotXMdLb031/DTXBVcVwcKE+z29ZzKul/ZQf1xyBQ
# FbvqEbsjeBplOoYwlIfnZsnExCvpza3mGK9F49UIjR4Fg98DkOAy145xkiTG/lO1
# AWcBo5k6IgniKePSeus4TROMEFDh9/TrK7Shx4PFvLQYTsN088WtIBd1nM/Ab0XW
# PlBpoKJN2tVCJs/t7L7t7r0WnHdhiqNcM7CdUAgWwrcIyRHhNfHFoR8tZmXG+D1X
# DcVD832wLqTxfhEZDZf6MOWyFM/p75pVdpUjMK6L7BRtLqmq7+3sltGgVTuCy23O
# TvKMzZ0MgzzSIQ57/XIZyyUl6VpaEBR8vjxIjVfPCgSWUISK9jNatLFHQeZJmQ0Y
# ZbEmhBNFGbcHI+lSXrTXiVJQ65U9VdpK5Q+iD4GWvzToNN3bsjiqRGZ1cn0z0gUC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBQ03ANXWvlTdHvR/foC/vNWzgmesjAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAVBdJbvLNhLsdPPzEhg+/bkLJeRDxAcsUg/np
# uOGDq8SCzm7jXTCjm8ZTENfAxH/2guw/nrBZLOe5kLbPj3gPLgYm9k9GOsBhswMi
# 48rtl6V0gb1OOckVQQkCSQXyjyOsjIzIgpIexnufffawOeDC5t2rrMpOvx1mtqVn
# fNZIGMpygpoGh5qbF/P74uhNuaM52UEA3+VxXUf9dSUP9LgYzY4kLHrnJulkSQ6Q
# HixMa2ImGNYiGP7ftpe8k8dkvjbGzTouoljlqCqHiJmYrjPl68x9rPr3+kilKuem
# vawyLtQ6zb0WzvSKLSv6LvE8DbmuAecnbR8CjDNyeKiVqnyY7YVKh8xcKXGv20MW
# FViRNrJwD662RmKjOrrpfEi+LzTVffR7FB9ITRnflMCboRiPIm4unHv7zKGFDP2e
# 7QoW17dAy0QGGBeR40Ux/zDFU2YCRMB80OxUYEgmp6jH06dIWeR65b/wAm2yb2h0
# ka4bgSe77B5L/eZFRi2WwY7f7BFC36Hp/fXkMMo5Q8XHEDQfQtUHWY3xRD1sCiRU
# T0g9JvA9U2+tRh/UXr+rnHW91EIW2xqrEwLCnwrR6YqmH4VK4LSQJ85/mtrDzE0w
# KOhBcZCPgKSFYxYTXDIXg5q1xeE32Y8i1BYYq3GdG7uXU7tTnNE3WcLtI2idcLTd
# yBtXoZowggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAWxPKLDixcu4ygj3RSJig/nteDBSggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO6XBLowIhgPMjAyNjEx
# MDUxMzM1NTRaGA8yMDI2MTEwNjEzMzU1NFowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7pcEugIBADAHAgEAAgIH7zAHAgEAAgIS5jAKAgUA7phWOgIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAClAEcOTPlE/3P1SntDvN4xbc32w7AUxIg35xY
# bzZWT3qPLs+OOX5WZV1k2hJnnuKBlhdl248DBk5UuPQtyhAemYXvEl7J6OgVTCzP
# c6NXtQa42PdDiLDPZzMlK9IhKjFOifeAyq1j9BDkb3mbbJkPZ9dSxVYQqO3yJIhg
# Kt5/n2QEkL/VNTowgnXr2sTw1j1QDMA+8zZoFuTgdJ9kajOjX2VCOlwzqexlMrfd
# G7/xikMkzPw8omTzIt1xnHGJpPc8KwTahmMOfVdqXljm74K0UD6lN5pnCu2mUgyq
# i4FMU0/eQ7ykgSeLL8K0rbpeD8l4pud1kdx4AjTTlQ+Iz7ooMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIzEF+3NtqoQFIA
# AQAAAjMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQggY7TayupOTrEORy72hE6urnqThjVf3x8Ms8M
# 4fUQSe0wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCWue5iC0tIXWaU0QT/
# Up3MULZUb5U9e96q40RB0g45lzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACMxBftzbaqEBSAAEAAAIzMCIEIN/N/hEJXQnyb+MR/Fys
# wwsVNa/vyUBNL8Z5eneb50puMA0GCSqGSIb3DQEBCwUABIICAB5K45cs0XYHtqMD
# XvXCxgCGJiaej4QhS1YtVswWr7gaTATctK7b3tLdSDgBusTBoW8qRIShQA+bm/eR
# kdt0m1jWn2Z0uMi5k3W6iz4DEQ33cA4UcgpFVImOhuDKQnsDNfU+nPKm0c0Rd3RF
# SMOFGpT0QMde3b35ED7lNCB9UehMwMfxxtdTSJFnD+t3EsFCG96kLfoEqEYMhZ+j
# UldojC0pdIr95rUUdxJZ+srQm6R3bWMxl3A7emOYzexqfhqpIvC4Wq2QjtYHcuDJ
# QLm93uwvKaooRAJ0e/0BwtSoEb9+XrWEeyLHpkxqzqHlO7vGpp0XO1bQPlo+hfej
# k4BHgrv+KkDUoA9ElB5OkEpZT4xGGHA0kEQ8S/U/FiobuQhX57zDwEJLmyf1dxLg
# r6y0GoZZ63STla6e0Mec9BrsYdM4R8nT68Qo4ALQHa0TemB9QYCUtm0f/Z4A4Hjc
# XfnBMorYcuIyEIcYTsIFSM1SSXHEZUO3ZkCBgavIS0/aKQzcvo7YSI3Hl4put14i
# 6QaNbdcPxq8YckmR7c4PK/myszAg4O4fTxtTSCtrvLxN292yB6MfYE6WMKm2bHes
# VUYr3mJrWClbMqnFDBddoYULvt8/go4DWQ0lcy6fmN4sMcThKjZla/d+89igAvGP
# TV9LeLJ62g+xsY4yh7gvT02Sxl9F
# SIG # End signature block
