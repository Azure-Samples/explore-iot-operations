# Test the Edge Historian API
# Run this in a separate PowerShell window while app.py is running

$baseUrl = "http://localhost:8080"

Write-Host "Testing Edge Historian API" -ForegroundColor Cyan
Write-Host "=" * 60

# Test 1: Health Check
Write-Host "`n[1] Health Check" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 2: Get Statistics (should be empty initially)
Write-Host "`n[2] Database Statistics" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/stats" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 3: Insert test data directly into database
Write-Host "`n[3] Inserting test data..." -ForegroundColor Yellow
$testMessages = @(
    @{
        topic = "factory/cnc"
        payload = @{
            machine_id = "CNC-01"
            station_id = "LINE-1-STATION-A"
            status = "running"
            part_type = "HullPanel"
            part_id = "HP-1001"
            cycle_time = 12.5
            quality = "good"
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    },
    @{
        topic = "factory/welding"
        payload = @{
            machine_id = "WELD-01"
            station_id = "LINE-2-STATION-C"
            status = "running"
            assembly_type = "FrameAssembly"
            assembly_id = "A-123"
            quality = "good"
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    },
    @{
        topic = "factory/3dprinter"
        payload = @{
            machine_id = "3DP-03"
            station_id = "LINE-1-STATION-B"
            status = "running"
            part_type = "GearboxCasing"
            part_id = "P-456"
            progress = 0.65
            quality = $null
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
)

foreach ($msg in $testMessages) {
    $sql = "INSERT INTO mqtt_history (timestamp, topic, payload, qos) VALUES (NOW(), '$($msg.topic)', '$($msg.payload | ConvertTo-Json -Compress)', 0);"
    docker exec historian-postgres psql -U historian -d mqtt_historian -c $sql 2>$null
    Write-Host "  ✓ Inserted message to $($msg.topic)" -ForegroundColor Green
}
Start-Sleep -Seconds 1

# Test 4: Query last value for CNC topic
Write-Host "`n[4] Get Last Value - factory/cnc" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/last-value/factory/cnc" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 5: Query last value for welding topic
Write-Host "`n[5] Get Last Value - factory/welding" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/last-value/factory/welding" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 6: Query by machine_id
Write-Host "`n[6] Query by machine_id=CNC-01" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/query?machine_id=CNC-01&limit=10" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 7: Query by topic
Write-Host "`n[7] Query by topic=factory/3dprinter" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/query?topic=factory/3dprinter&limit=5" -Method Get
$response | ConvertTo-Json -Depth 3
Start-Sleep -Seconds 1

# Test 8: Get updated statistics
Write-Host "`n[8] Updated Statistics" -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "$baseUrl/api/v1/stats" -Method Get
$response | ConvertTo-Json -Depth 3

Write-Host "`n" + ("=" * 60)
Write-Host "All tests completed!" -ForegroundColor Green
Write-Host ("=" * 60)
