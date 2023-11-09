#!/bin/bash

# Function to print in green
print_green() {
    echo -e "\033[32m$1\033[0m"
}


# Fetch the currently active subscription
echo -e "\nFetching the currently active subscription..."
CURRENT_SUBSCRIPTION=$(az account show --query "name" -o tsv 2>/dev/null)
if [ -z "$CURRENT_SUBSCRIPTION" ]; then
    echo -e "\nError: Failed to fetch the currently active Azure subscription. Please run 'az login' to set up an account.\n"
    exit 1
fi

echo -e "\n"
read -p "Is \"$(print_green "$CURRENT_SUBSCRIPTION")\" the right subscription to use? (y/n): " RESPONSE
echo -e "\n"

if [[ "$RESPONSE" != "y" ]]; then
    echo -e "Please use 'az account set' command to set the right subscription and then rerun the script.\n"
    exit 1
fi

# Default values
DEFAULT_LOCATION="westus3"
DEFAULT_RESOURCE_GROUP="$CODESPACE_NAME"
CLUSTER_NAME="iotops-quickstart-cluster"
SUPPORTED_LOCATIONS=("eastus" "eastus2" "westus2" "westus3")

# Ask the user if they want to provide their own values
echo -e "\n"
read -p "Do you want to provide your own values for location and resource group? (y/n): " CUSTOM_VALUES
echo -e "\n"

if [[ "$CUSTOM_VALUES" == "y" ]]; then
    # User provides their own values
    while true; do
        read -p "Enter the resource group name: " RESOURCE_GROUP
        
        # Check if the provided resource group exists
        echo -e "\nChecking if the resource group $RESOURCE_GROUP exists..."
        az group show --name $RESOURCE_GROUP &> /dev/null
        if [ $? -eq 0 ]; then
            # Resource group exists, check if it's in a supported location
            echo -e "\nChecking the location of the resource group $RESOURCE_GROUP..."
            RG_LOCATION=$(az group show --name $RESOURCE_GROUP --query "location" -o tsv)
            if [[ " ${SUPPORTED_LOCATIONS[@]} " =~ " ${RG_LOCATION} " ]]; then
                LOCATION=$RG_LOCATION
                break
            else
                echo -e "\nError: The resource group $RESOURCE_GROUP exists but is not in a supported location. Supported locations are: ${SUPPORTED_LOCATIONS[*]}.\n"
                read -p "Do you want to specify a different resource group and location? (y/n): " TRY_AGAIN
                if [[ "$TRY_AGAIN" != "y" ]]; then
                    exit 1
                fi
            fi
        else
            # Resource group does not exist, ask for location and create it
            while true; do
                read -p "Enter the location (Supported: eastus, eastus2, westus2, westus3): " LOCATION
                if [[ " ${SUPPORTED_LOCATIONS[@]} " =~ " ${LOCATION} " ]]; then
                    break
                else
                    echo -e "\nError: The location $LOCATION is not supported. Please choose from eastus, eastus2, westus2, or westus3.\n"
                fi
            done
            echo -e "\nCreating resource group $RESOURCE_GROUP in location $LOCATION..."
            az group create --name $RESOURCE_GROUP --location $LOCATION --output table
            if [ $? -ne 0 ]; then
                echo -e "\nError: Failed to create the resource group.\n"
                exit 1
            fi
            break
        fi
    done
else
    # User chooses to use default values
    RESOURCE_GROUP=$DEFAULT_RESOURCE_GROUP
    LOCATION=$DEFAULT_LOCATION
    
    # Check if the default resource group exists and create it if it doesn’t
    echo -e "\nChecking if the default resource group $RESOURCE_GROUP exists..."
    az group show --name $RESOURCE_GROUP &> /dev/null
    if [ $? -ne 0 ]; then
        echo -e "\nCreating default resource group $RESOURCE_GROUP in location $LOCATION..."
        az group create --name $RESOURCE_GROUP --location $LOCATION --output table
        if [ $? -ne 0 ]; then
            echo -e "\nError: Failed to create the default resource group.\n"
            exit 1
        fi
    fi
fi
# Add the connectedk8s extension
echo -e "\nAdding the connectedk8s extension..."
az extension add --name connectedk8s
if [ $? -ne 0 ]; then
    echo -e "\nError: Failed to add the connectedk8s extension.\n"
    exit 1
fi

# Connect the Kubernetes cluster to Azure Arc
echo -e "\nConnecting the Kubernetes cluster to Azure Arc..."
az connectedk8s connect --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP
if [ $? -ne 0 ]; then
    echo -e "\nError: Failed to connect the Kubernetes cluster to Azure Arc.\n"
    exit 1
else
  
    # After the connection to Azure Arc
    echo -e "\nTo manually export the cluster name and resource group for later use, run the following commands in your terminal:\n"
    echo -e "$(print_green "export CLUSTER_NAME=$CLUSTER_NAME")"
    echo -e "$(print_green "export RESOURCE_GROUP=$RESOURCE_GROUP")"

    # Determine the directory of the script
    SCRIPT_DIR="$(dirname "$0")"

    echo -e "\nSaving environment variables for reference...\n"
    cat <<EOL > $SCRIPT_DIR/env_vars.txt
export CLUSTER_NAME=$CLUSTER_NAME
export RESOURCE_GROUP=$RESOURCE_GROUP
EOL

    echo -e "A file named $(print_green "env_vars.txt") has been created with environment variables above..."
    echo -e "\nTo set the environment variables, run:"
    echo -e "\033[32msource $SCRIPT_DIR/env_vars.txt\033[0m"

fi