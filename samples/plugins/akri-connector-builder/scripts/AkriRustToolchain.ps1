#requires -Version 7.0
# Shared Rust toolchain-pin parsing for the launcher gate and the container validation script.
# Dot-source only; this file defines functions and performs no work.

Set-StrictMode -Version Latest

$script:AkriDefaultRustBaseImage = 'mcr.microsoft.com/azurelinux/base/rust:1.90'

function Get-AkriDockerfileRustToolchain {
    <#
    .SYNOPSIS
    Reads the pinned rustup toolchain and build base image from a connector Dockerfile.
    .OUTPUTS
    An object with RustVersion, MajorMinor, BaseImage, and Error (null when valid).
    #>
    param([Parameter(Mandatory)][string]$DockerfilePath)

    $result = [pscustomobject]@{ RustVersion = $null; MajorMinor = $null; BaseImage = $script:AkriDefaultRustBaseImage; Error = $null }
    if (-not (Test-Path -LiteralPath $DockerfilePath -PathType Leaf)) {
        $result.Error = "Dockerfile '$([IO.Path]::GetFileName($DockerfilePath))' does not exist."
        return $result
    }
    $lines = [IO.File]::ReadAllLines($DockerfilePath)
    $argument = $lines | Where-Object { $_ -match '^\s*ARG\s+RUST_VERSION\s*=' } | Select-Object -First 1
    if (-not $argument) {
        $result.Error = 'Dockerfile does not declare ARG RUST_VERSION.'
        return $result
    }
    if ($argument -notmatch '^\s*ARG\s+RUST_VERSION\s*=\s*"?(?<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?)"?\s*$') {
        $result.Error = 'Dockerfile ARG RUST_VERSION is not a concrete major.minor[.patch] toolchain version.'
        return $result
    }
    $result.RustVersion = $Matches.version
    $result.MajorMinor = ($Matches.version -split '\.')[0..1] -join '.'
    $from = $lines | Where-Object { $_ -match '^\s*FROM\s+(?<image>[A-Za-z0-9][A-Za-z0-9._/:@-]*)\s+AS\s+build-env\s*$' } |
        Select-Object -First 1
    if ($from -and $from -match '^\s*FROM\s+(?<image>\S+)') { $result.BaseImage = $Matches.image }
    return $result
}

function Get-AkriCargoRustVersion {
    <#
    .SYNOPSIS
    Returns the rust-version declared by a Cargo manifest's [package] (or inherited [workspace.package]).
    .OUTPUTS
    The declared version string, or $null when absent.
    #>
    param([Parameter(Mandatory)][string]$ManifestPath)

    $section = ''
    $declared = @{}
    $inherits = $false
    foreach ($line in [IO.File]::ReadAllLines($ManifestPath)) {
        if ($line -match '^\s*\[\[') { $section = ''; continue }
        if ($line -match '^\s*\[\s*([^\]]+?)\s*\]\s*(?:#.*)?$') { $section = $Matches[1]; continue }
        if ($section -notin @('package', 'workspace.package')) { continue }
        if ($line -match '^\s*rust-version\s*=\s*"(?<version>[^"]*)"\s*(?:#.*)?$') {
            $declared[$section] = $Matches.version
        } elseif ($section -eq 'package' -and
            $line -match '^\s*rust-version(?:\.workspace\s*=\s*true|\s*=\s*\{\s*workspace\s*=\s*true\s*\})\s*(?:#.*)?$') {
            $inherits = $true
        }
    }
    if ($declared.ContainsKey('package')) { return $declared['package'] }
    if ($inherits -and $declared.ContainsKey('workspace.package')) { return $declared['workspace.package'] }
    return $null
}

function Test-AkriRustToolchainPin {
    <#
    .SYNOPSIS
    Checks that Cargo.toml rust-version equals the Dockerfile.release RUST_VERSION major.minor and
    that a Cargo.lock exists, so the resolved dependency graph targets the container toolchain.
    .PARAMETER ProjectPath
    The inner connector project directory containing Cargo.toml and Dockerfile.release.
    .PARAMETER AllowMissingLock
    Skips the Cargo.lock requirement (used while the lock file is being generated).
    .OUTPUTS
    An object with Passed, RustVersion, MajorMinor, ManifestRustVersion, BaseImage, LockPresent, and Errors.
    #>
    param([Parameter(Mandatory)][string]$ProjectPath, [switch]$AllowMissingLock)

    $errors = [Collections.Generic.List[string]]::new()
    $toolchain = Get-AkriDockerfileRustToolchain (Join-Path $ProjectPath 'Dockerfile.release')
    if ($toolchain.Error) { $errors.Add($toolchain.Error) }
    $manifestPath = Join-Path $ProjectPath 'Cargo.toml'
    $manifestVersion = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $errors.Add('Cargo.toml does not exist.')
    } else {
        $manifestVersion = Get-AkriCargoRustVersion $manifestPath
        if (-not $manifestVersion) {
            $errors.Add('Cargo.toml [package] does not declare rust-version.')
        } elseif ($toolchain.MajorMinor -and $manifestVersion -cne $toolchain.MajorMinor) {
            $errors.Add("Cargo.toml rust-version '$manifestVersion' must equal Dockerfile RUST_VERSION major.minor '$($toolchain.MajorMinor)'.")
        }
    }
    $lockPresent = Test-Path -LiteralPath (Join-Path $ProjectPath 'Cargo.lock') -PathType Leaf
    if (-not $lockPresent -and -not $AllowMissingLock) {
        $errors.Add('Cargo.lock does not exist; resolve it with the container lock command.')
    }
    [pscustomobject]@{
        Passed = $errors.Count -eq 0
        RustVersion = $toolchain.RustVersion
        MajorMinor = $toolchain.MajorMinor
        ManifestRustVersion = $manifestVersion
        BaseImage = $toolchain.BaseImage
        LockPresent = $lockPresent
        Errors = @($errors)
    }
}

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBLToL8k/elcjoB
# fqkHoBOtk9w7UBk19Q4pghZJpmwdH6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEILiZ6pYTvVPswxM+/3Kn8rD199ryJkrrMUA71HU/JJkBMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAp/luM5IfvGQAE37d
# LCZrau0j9+N2KZjsoOoi3gAWJbdSJHRw/WeY8tN66fC8DS5lyJMGrnviHzDnyJfD
# yI/jk6gwanEgzb/EYFzgM24JdcNc24yI2xs9ZbIHvUU3vYBm8YyUsEa5UJiquLzR
# fJpzIu+22KLQzG/d++Zr6PLfEnZ1+D2bqGzlUhVLywfMOA7pzf2il88elXP86M/1
# R38He6hGxydWwHvOnu03ZYOgzsPdoKUIoZ88qHPmzYpT64Bj5ZH0QYssSIq/nrtW
# l1JAl+V4WqRtKsP27i0s2ZKN+sknZ7BW+IY9w7kPutgAbHlAWlAPEXfqRnE/IuDf
# vV0W56GCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAVVg6ZkE9IcmFO
# VH/sf68NXcgj0XPHDawfRTA7bXGLogIGaqqs3/cgGBMyMDI2MTEwNTIxNTgyOS4x
# NjhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RTAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAikO1WQqtJfyGgABAAACKTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDdaFw0yNzA1MTcxOTQwMDda
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046RTAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCe
# ItFq4z1oCYSmUZmpYDsbJWEu++1bbc/Mz7Pa3I0ZX5EON+WirB0FvnGlyFRUylzO
# 5TJXZfU8QFPOU95P1Y1OZ8J+quA5G+AWSBOr/48scl0s9RBpqgTMq/lbyqBz4CMm
# vVR2QevAgVp4a1hbmOm9G7YWey68N5F5rSDYV0wMlg4Iy8YRuFgRN2eBpVXt9IvF
# aFmBnQLZfo22KZ3L8PWEHUhXU5dLOSZoTfqqQ/B+deW56ACMnnHjPxZu+szHhZML
# UrMWTgs9J7Cn8DtelcKj9aM+0Zq7tkSDHCrwo6eCSfw3clktXRRrdmsccal8RCDi
# NFFgZsypwF2aGAF6kg41+Ql+thXpnOMUH4mPCAJZWp0zDWowsK/Yo5jHL1pT/Agb
# L3FoAy4cbhOI4Pb1eQFG+jT7skS2F/b+ZACUA1EDZ830K+Bu0yw+FpSGy8tpd1sz
# k3cUYjIpzIG4z3oFNmiSJN8YdNd4SHsER5Dks5bxiKbpvmfrOA39jTb7EW2TT7yS
# WgJISfvTezuLmQsTVSzNsvapVlHhE2zBqDw409nvOtitCFbnhhXNfatzb2+Gf2tX
# 2s6YBa151CC/8+emJvvegXbWNudzYt8cFRom0PZ+fJRhhBfdSqCqr8QeOGJ8VYlm
# xFXqx1SdDSkTCSgpsskGqZwh/6umA1g4L7zeGBNngQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFCdNRaSL9AW8QvaQ21WjRAXKN4M7MB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA9wc72lf/czDhp09T3PGAMOQhxl/x04jpE7t39FeqQSn2Up6DVzhgwnzCq
# Y3NIhLtUaWrd7NxvrhZDca+J4xzvrRQNPHeRQpnJVeHsyTu53gTBlUB1TRI6OnZt
# /AVmR9oMJ/NBOqB+d+SOb8Px6zRgRwk62sFkOkB5lig/DMnYEeR/amW9Hdo8vXcK
# maa/DbSOAHSdfZFt+iqMZfNlkEOn71/RAKTNv4Qpq/2FhcjMMmSkIhshBdBVB0Vj
# mkwFfhVUf5TTuLJ9sDR4EyCvOZJ3B6g7Iw6WjQxycjwkfzsVMTpfusJ5SwdOHL8y
# GPWZOePjwa8ISXWs6kiVK/6S0/JVb1LpxpyYKREQjnU/5OecKt2OXlHdwFWZrwAi
# 98RPZa6EExcb/LGLf10tNHju1eTlohY0jzNZQ0BDgSuMZgMU+8EEjtMQMIDnlPGE
# UON7LHXHH0KL0FA01PEWVZKrr/LUOuuDTNFzw543FPMp4gkCIFlKdRuciR1IXOk+
# Xse6rj9tJFYgVn+44BHou2XQe5RX30ef3AQWa0mxyGDqJzGsV3X5+bNQeMV88iWu
# lJPq5sgnGG9O/H1/HH4HsO9ZKGX/WrJpQmFuQrTOR49XjveaC0xaFmGsNg+RhbtD
# 5qTkn+ISDvw0IJ/E/VXNdz/yWgol6r507hT8sAMupnhkF2uw1DCCB3EwggVZoAMC
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
# U1MgRVNOOkUwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC3v9iSO22xob7ZxN5dXCEq+9Iv
# /6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7pcNDzAiGA8yMDI2MTEwNTE0MTEyN1oYDzIwMjYxMTA2MTQxMTI3
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDulw0PAgEAMAoCAQACAh3nAgH/MAcC
# AQACAhNEMAoCBQDumF6PAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAGTM
# 0nKLHm/kDSLKC07VNbn7qVSrv1WF4c+MQInMMEgJWa3Kyfjy8hR1VJBHNaFoXFnq
# XKhmqatGZxor4+qZTIy0OGLX7Ih0vL7mZLZ5Oea3xk7fDBBSDv9YywBgD00JsZNI
# CsiY8h4FHg1tO/KJCv0R8JUNmcZRNudDQRDYxpij897+vFkoqstCT/KEwICy3sEs
# xgOGjdUte3oKoJt1PNcVvZQfSg+/bTDUpKlDd06QcJ3cQjKghV/pRxnPkzbRAXQ8
# m0WAv9Ry4BZ84muwZTyHxolK+sffIN6gJfZx0rTTWU8D6awsgIczE0sr5iT4n7k0
# V4zonCtgf4l+Ql166dcxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAikO1WQqtJfyGgABAAACKTANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAC
# Y8P7Khybv0aGqQvN9v0MFDJDED/rfXHGp7Dg2k5RbjCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EILfKPfEitvD/lSvEumxqPkkeOEtgkmKFEVMuel9oOrqSMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIpDtVkKrSX
# 8hoAAQAAAikwIgQgrp+fxYhgIGb5JdbTnCdzKf8q9kglaBgp4tvUxyYVGQcwDQYJ
# KoZIhvcNAQELBQAEggIAjRQu9PTwf3/VWDdFJbS5jDZaSpSgTelLHNf/tRxxwf9R
# FmvPgbKVgWFqsCgiBvSbQpjzdOJ5CjXWzmCnKKXi/eWSyCM52bCOlBY25gLlMNJz
# J83D7YNVs68WbUOp/b+5F5uCnOhCJMr23dy593pMq1aQCZookE+7mXHezbvrayIt
# 88TY+7zaGTP6SIWLevieUrLrTsrr8uabCXQ0R2X4R/sv2s7sohwYHfHu8CIf8HAU
# fP03Mb+zdAuXaDYK6Rs4s2nGZpEK7A4ENh7C6bzCQqc7ttJbhIYySObR1pZfIqmw
# b2/Pta5MieaZRLXgyh7YzyP5dEK4bzfV7w+tS52KbO0e3Ahjb79BPykGgOcg5wQI
# b7mDMJdhTMz2cGXC8t1JwiwnjfUGxbVNKFj0j0T7Ai3o/0ATjuLLiD4vgqo9KaL6
# 4dBMRHExT+3yfxV2bhJUsw3ayAp8pU9gsiEbSxhrhuH7ZclnM44IRAbfWLyZ1OzB
# wxr82kzq58M0Dl6df8jxz++Wl7IQmvp3ZSjj49j4Ftjfr7UhUImv4ZsJ2x9m1rYr
# 6TbCjL8AmRbVAYHsmdX8/K7HgQQs1fKqDKC1KqQ/CtxOg7LtThSFS+a7alhNR8J7
# EI/eh5IX6RquOe6enfrd/JkQmLIDu/7D57QpCcxcbrSbL1/aYIrvHy/6/ZCRagY=
# SIG # End signature block
