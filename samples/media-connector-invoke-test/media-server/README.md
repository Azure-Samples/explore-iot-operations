The scripts in this directory help in installing, uninstalling, and managing a media server.

The scripts are written in PowerShell and use the kubectl to interact with the cluster.

The scripts are designed to be run on Windows and Linux.

## Prerequisites

- [kubectl](installation instructions: https://kubernetes.io/docs/tasks/tools/install-kubectl/)

## Usage

1. Open a PowerShell terminal.
2. Check the prerequisites: `pwsh Test-Prerequisites.ps1`.
3. Install the Media Server: `pwsh Install-MediaServer.ps1`
4. Check the Media Server after installation: `pwsh Test-MediaServer.ps1`
5. When you are done, uninstall the Media Server: `pwsh Uninstall-MediaServer.ps1`
