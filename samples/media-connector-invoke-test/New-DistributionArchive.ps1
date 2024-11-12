<#
    Create an archive for distribution.
#>

Write-Host "Creating archive..."

. ".\Update-Dependencies.ps1"
. ".\Update-MermaidDiagrams.ps1"

if (Test-Path "media-connector-demo.zip") {
    Write-Host "Removing existing archive..."
    Remove-Item "media-connector-demo.zip" -ErrorAction SilentlyContinue
}

Remove-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "*.bak") -Recurse -Force -ErrorAction SilentlyContinue

$archiveDirectory = (Join-Path -Path $PSScriptRoot -ChildPath "media-connector-demo")
Remove-Item -Path $archiveDirectory -Recurse -Force -ErrorAction SilentlyContinue

$excludeList = @(
    "media-connector-internal-demo.zip",
    "Create-DistributionArchive.ps1",
    "Update-Dependencies.ps1",
    "Update-MermaidDiagrams.ps1",
    "DEVELOPERS.md",
    ".config_aio_mq_*",
    ".config_media_server*",
    ".config_aio_connector_path")

Write-Host "Getting file list..."
$FileList = Get-ChildItem -Path $PSScriptRoot -Exclude $excludeList -Force

Write-Host "Files to archive:"
$FileList | Sort-Object -Property Directory, Name | Format-Table -AutoSize -Property Name, LinkType, Directory | Out-String | Write-Host

Write-Host "Copying files to archive directory..."
[void](New-Item -Path $archiveDirectory -ItemType Directory -Force)
Copy-Item -Path $FileList -Destination $archiveDirectory -Recurse -Force

Write-Host "Creating archive..."
$archiveFile = (Join-Path -Path $PSScriptRoot -ChildPath "media-connector-demo.zip")
Remove-Item -Path $archiveFile -Force -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::CreateFromDirectory($archiveDirectory, $archiveFile)

Write-Host "Done!"
