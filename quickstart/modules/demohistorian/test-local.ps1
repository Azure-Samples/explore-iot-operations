# Quick Local Test Script for Edge Historian
# Run this from PowerShell in the demohistorian directory

Write-Host "Edge Historian - Local Testing Setup" -ForegroundColor Cyan
Write-Host "=" * 60

# Check prerequisites
Write-Host "`nChecking prerequisites..." -ForegroundColor Yellow

# Check Python
try {
    $pythonVersion = python --version
    Write-Host "[OK] Python: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Python not found. Install Python 3.11+" -ForegroundColor Red
    exit 1
}

# Check Docker
try {
    $dockerVersion = docker --version
    Write-Host "[OK] Docker: $dockerVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Docker not found. Install Docker Desktop" -ForegroundColor Red
    exit 1
}

# Install Python dependencies
Write-Host "`nInstalling Python dependencies..." -ForegroundColor Yellow
pip install -q -r requirements.txt
Write-Host "[OK] Dependencies installed" -ForegroundColor Green

# Start PostgreSQL container
Write-Host "`nStarting PostgreSQL container..." -ForegroundColor Yellow
$existingContainer = docker ps -a --filter "name=historian-postgres" --format "{{.Names}}"
if ($existingContainer -eq "historian-postgres") {
    Write-Host "Container already exists, removing..." -ForegroundColor Yellow
    docker stop historian-postgres 2>$null
    docker rm historian-postgres 2>$null
}

docker run --name historian-postgres -d `
  -e POSTGRES_DB=mqtt_historian `
  -e POSTGRES_USER=historian `
  -e POSTGRES_PASSWORD=changeme `
  -p 5432:5432 `
  postgres:16-alpine

Write-Host "[OK] PostgreSQL started" -ForegroundColor Green
Write-Host "  Waiting for database to be ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Set environment variables
Write-Host "`nSetting environment variables..." -ForegroundColor Yellow
$env:POSTGRES_HOST = "localhost"
$env:POSTGRES_PORT = "5432"
$env:POSTGRES_DB = "mqtt_historian"
$env:POSTGRES_USER = "historian"
$env:POSTGRES_PASSWORD = "changeme"
$env:MQTT_ENABLED = "false"
$env:LOG_LEVEL = "INFO"

Write-Host "[OK] Environment configured" -ForegroundColor Green

# Display configuration
Write-Host "`nConfiguration:" -ForegroundColor Cyan
Write-Host "  Database: localhost:5432/mqtt_historian"
Write-Host "  MQTT: Disabled (local testing mode)"
Write-Host "  HTTP API: http://localhost:8080"

Write-Host "`n" + ("=" * 60)
Write-Host "Ready to start!" -ForegroundColor Green
Write-Host ("=" * 60)

Write-Host "`nStarting Edge Historian..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop`n" -ForegroundColor Gray

# Run the application
try {
    python app.py
} finally {
    Write-Host "`n`nCleaning up..." -ForegroundColor Yellow
    docker stop historian-postgres 2>$null
    docker rm historian-postgres 2>$null
    Write-Host "[OK] Cleanup complete" -ForegroundColor Green
}
