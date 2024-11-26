Write-Host "Testing the prerequisites..."

Write-Host "Checking for kubectl..."
If (-not (Get-Command -Name "kubectl" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: kubectl not found, make sure it is installed and accessible"
    Exit 1
} Else {
    Write-Host "kubectl found!"
}

Write-Host "Done!`n"
