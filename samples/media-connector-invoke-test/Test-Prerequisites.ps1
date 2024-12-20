#Requires -Version 7
<#
    Testing the prerequisites for the scripts in this package.
#>

Write-Host "Testing the prerequisites..."

If ($PSScriptRoot -match " ") {
    Throw "Error: The script path contains spaces."
    Exit 1
} Else {
    Write-Host "The script path does not contain spaces!"
}

Write-Host "Checking for kubectl..."
If (-not (Get-Command -Name "kubectl" -ErrorAction SilentlyContinue)) {
    Throw "Error: kubectl not found, make sure it is installed and accessible."
    Exit 1
} Else {
    Write-Host "kubectl found!"
}

Write-Host "Checking for mosquitto_pub..."
If (-not (Get-Command -Name "mosquitto_pub" -ErrorAction SilentlyContinue)) {
    Throw "Error: mosquitto_pub not found, make sure it is installed and accessible."
    Exit 1
} Else {
    Write-Host "mosquitto_pub found!"
}

Write-Host "Checking for mosquitto_sub..."
If (-not (Get-Command -Name "mosquitto_sub" -ErrorAction SilentlyContinue)) {
    Throw "Error: mosquitto_sub not found, make sure it is installed and accessible."
    Exit 1
} Else {
    Write-Host "mosquitto_sub found!"
}

Write-Host "Checking if a default cluster is configured..."
# Define the command to get the current kubectl context
$kubectlContextCommand = "kubectl config current-context"
# Execute the command and capture the output
$currentContext = Invoke-Expression $kubectlContextCommand
# Check if the output is empty
if ([string]::IsNullOrWhiteSpace($currentContext)) {
    Throw "No Kubernetes cluster is currently configured."
    Exit 1
} else {
    Write-Host "Current Kubernetes context: $currentContext"
}

Write-Host "Prerequisites are met!`n"
