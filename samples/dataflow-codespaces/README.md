# Azure IoT Operations Data Flow in Codespaces

This sample sets up a GitHub Codespace with the Azure IoT Operations Data Flow extension and
the dependencies needed to use it in your browser.

## Get started

1. Copy this sample's `.devcontainer/` directory into the root of your application repository.
1. Commit the files to the branch you want to use.
1. On GitHub, select that branch and choose **Code > Codespaces > Create codespace**.
1. Wait for setup to install the extension and prepare its runtime images.
1. Trust the workspace only after reviewing its contents, then use **Azure IoT Operations Data Flow**
   in the browser editor.

For an existing Codespace, run **Codespaces: Rebuild Container** after adding the configuration.
The configuration installs Azure CLI, Docker, and ORAS. Setup pulls and tags `host-app`,
`devx`, `statestore-cli`, and `aio-vscode-mcp`; it does not start these containers.

## Azure and Docker access

When an Azure feature prompts you to sign in, complete the Microsoft sign-in flow in your browser.
Your account needs access to the Azure resources you use. Commands that use Azure CLI also require
CLI authentication through your organization's approved method. Copilot features require GitHub
Copilot access and sign-in.

Docker-in-Docker requires a privileged devcontainer.
