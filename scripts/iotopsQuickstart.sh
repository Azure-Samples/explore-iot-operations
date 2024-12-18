#!/bin/bash

# Function to print in green
print_green() {
    echo -e "\033[32m$1\033[0m"
}

# Check current Azure subscription
echo "Checking current Azure subscription..."
CURRENT_SUBSCRIPTION=$(az account show --query "name" -o tsv 2>/dev/null)
if [ -z "$CURRENT_SUBSCRIPTION" ]; then
    echo "Error: No active Azure subscription found. Please run 'az login' to set up an account."
    exit 1
fi

echo "Current subscription: $(print_green "$CURRENT_SUBSCRIPTION")"
read -p "Is this the correct subscription? (y/n): " RESPONSE

if [[ "$RESPONSE" != "y" ]]; then
    echo "Please use 'az account set' to select the correct subscription and rerun the script."
    exit 1
fi

# Default values
DEFAULT_LOCATION="westus2"
DEFAULT_RESOURCE_GROUP="${CODESPACE_NAME:-default-rg}"
CLUSTER_NAME="iotops-quickstart-cluster"
SUPPORTED_LOCATIONS=("eastus" "eastus2" "westus2" "westus" "westeurope" "northeurope")

# Prompt for custom values
read -p "Provide custom location and resource group? (y/n): " CUSTOM_VALUES

if [[ "$CUSTOM_VALUES" == "y" ]]; then
    # User provides custom values
    while true; do
        read -p "Enter resource group name: " RESOURCE_GROUP

        # Check if the resource group exists
        echo "Checking if resource group '$RESOURCE_GROUP' exists..."
        az group show --name "$RESOURCE_GROUP" &> /dev/null
        if [ $? -eq 0 ]; then
            # Resource group exists, check location
            RG_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv)
            if [[ " ${SUPPORTED_LOCATIONS[*]} " == *" $RG_LOCATION "* ]]; then
                LOCATION="$RG_LOCATION"
                break
            else
                echo "Error: Resource group is in unsupported location '$RG_LOCATION'."
                echo "Supported locations: ${SUPPORTED_LOCATIONS[*]}."
                read -p "Try a different resource group? (y/n): " TRY_AGAIN
                [[ "$TRY_AGAIN" != "y" ]] && exit 1
            fi
        else
            # Resource group does not exist
            read -p "Enter location for new resource group (Supported: ${SUPPORTED_LOCATIONS[*]}): " LOCATION
            if [[ " ${SUPPORTED_LOCATIONS[*]} " == *" $LOCATION "* ]]; then
                echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
                az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
                [ $? -ne 0 ] && echo "Error: Failed to create resource group." && exit 1
                break
            else
                echo "Error: Unsupported location '$LOCATION'."
            fi
        fi
    done
else
    # Use default values
    RESOURCE_GROUP="$DEFAULT_RESOURCE_GROUP"
    LOCATION="$DEFAULT_LOCATION"

    # Check if default resource group exists, create if not
    echo "Checking if resource group '$RESOURCE_GROUP' exists..."
    az group show --name "$RESOURCE_GROUP" &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        [ $? -ne 0 ] && echo "Error: Failed to create resource group." && exit 1
    fi
fi

# Ensure connectedk8s extension is installed
echo "Ensuring 'connectedk8s' extension is installed..."
az extension add --name connectedk8s --only-show-errors &> /dev/null

# Check if cluster is already connected
echo "Checking if cluster '$CLUSTER_NAME' is connected to Azure Arc..."
az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null
if [ $? -eq 0 ]; then
    echo "Cluster '$CLUSTER_NAME' is already connected."
else
    echo "Connecting cluster '$CLUSTER_NAME' to Azure Arc..."
    az connectedk8s connect --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
    [ $? -ne 0 ] && echo "Error: Failed to connect cluster to Azure Arc." && exit 1
fi

# Save environment variables
SCRIPT_DIR="$(dirname "$0")"
ENV_VARS_FILE="$SCRIPT_DIR/env_vars.txt"

echo "Saving environment variables to '$ENV_VARS_FILE'..."
cat <<EOL > "$ENV_VARS_FILE"
export CURRENT_SUBSCRIPTION="$CURRENT_SUBSCRIPTION"
export RESOURCE_GROUP="$RESOURCE_GROUP"
export LOCATION="$LOCATION"
export CLUSTER_NAME="$CLUSTER_NAME"
EOL

# Derive unique names based on Codespace
echo "Deriving unique resource names..."
if [ -z "$CODESPACE_NAME" ]; then
    echo "Error: 'CODESPACE_NAME' environment variable is not set."
    exit 1
fi

UNIQUE_SUFFIX=$(echo "$CODESPACE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
UNIQUE_SUFFIX=${UNIQUE_SUFFIX:0:18}

STORAGE_ACCOUNT="st${UNIQUE_SUFFIX}"
STORAGE_ACCOUNT=${STORAGE_ACCOUNT:0:24}

SCHEMA_REGISTRY="sr${UNIQUE_SUFFIX}"
SCHEMA_REGISTRY_NAMESPACE="srn${UNIQUE_SUFFIX}"

echo "Storage Account: $(print_green "$STORAGE_ACCOUNT")"
echo "Schema Registry: $(print_green "$SCHEMA_REGISTRY")"
echo "Schema Registry Namespace: $(print_green "$SCHEMA_REGISTRY_NAMESPACE")"

# Append to env_vars.txt
cat <<EOL >> "$ENV_VARS_FILE"
export UNIQUE_SUFFIX="$UNIQUE_SUFFIX"
export STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
export SCHEMA_REGISTRY="$SCHEMA_REGISTRY"
export SCHEMA_REGISTRY_NAMESPACE="$SCHEMA_REGISTRY_NAMESPACE"
EOL

# Create storage account if it doesn't exist
echo "Checking if storage account '$STORAGE_ACCOUNT' exists..."
az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &> /dev/null
if [ $? -ne 0 ]; then
    echo "Creating storage account '$STORAGE_ACCOUNT'..."
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --location "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --enable-hierarchical-namespace true \
        --sku Standard_RAGRS \
        --kind StorageV2 \
        --output none
    [ $? -ne 0 ] && echo "Error: Failed to create storage account." && exit 1
else
    echo "Storage account '$STORAGE_ACCOUNT' already exists."
fi

# Get Storage Account Resource ID
SA_RESOURCE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
echo "export SA_RESOURCE_ID=\"$SA_RESOURCE_ID\"" >> "$ENV_VARS_FILE"

# Create schema registry if it doesn't exist
echo "Checking if schema registry '$SCHEMA_REGISTRY' exists..."
az iot ops schema registry show --name "$SCHEMA_REGISTRY" --resource-group "$RESOURCE_GROUP" &> /dev/null
if [ $? -ne 0 ]; then
    echo "Creating schema registry '$SCHEMA_REGISTRY'..."
    az iot ops schema registry create \
        --name "$SCHEMA_REGISTRY" \
        --resource-group "$RESOURCE_GROUP" \
        --registry-namespace "$SCHEMA_REGISTRY_NAMESPACE" \
        --sa-resource-id "$SA_RESOURCE_ID" \
        --output none
    [ $? -ne 0 ] && echo "Error: Failed to create schema registry." && exit 1
else
    echo "Schema registry '$SCHEMA_REGISTRY' already exists."
fi

# Initialize IoT Ops if not already initialized
echo "Initializing IoT Operations on cluster..."
az iot ops show --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null
if [ $? -ne 0 ]; then
    az iot ops init --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
    [ $? -ne 0 ] && echo "Error: Failed to initialize IoT Operations." && exit 1
else
    echo "IoT Operations already initialized on cluster."
fi

# Get Schema Registry Resource ID
SR_RESOURCE_ID=$(az iot ops schema registry show --name "$SCHEMA_REGISTRY" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
echo "export SR_RESOURCE_ID=\"$SR_RESOURCE_ID\"" >> "$ENV_VARS_FILE"

# Create IoT Ops instance if it doesn't exist
INSTANCE_NAME="${CLUSTER_NAME}-instance"
echo "Checking if IoT Operations instance '$INSTANCE_NAME' exists..."
az iot ops show --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$INSTANCE_NAME" &> /dev/null
if [ $? -ne 0 ]; then
    echo "Creating IoT Operations instance '$INSTANCE_NAME'..."
    az iot ops create \
        --cluster "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$INSTANCE_NAME" \
        --sr-resource-id "$SR_RESOURCE_ID" \
        --broker-frontend-replicas 1 \
        --broker-frontend-workers 1 \
        --broker-backend-part 1 \
        --broker-backend-workers 1 \
        --broker-backend-rf 2 \
        --broker-mem-profile Low \
        --output none
    [ $? -ne 0 ] && echo "Error: Failed to create IoT Operations instance." && exit 1
else
    echo "IoT Operations instance '$INSTANCE_NAME' already exists."
fi

echo "export INSTANCE_NAME=\"$INSTANCE_NAME\"" >> "$ENV_VARS_FILE"

# Completion message
echo -e "\n$(print_green 'Setup completed successfully!')"
echo "Environment variables saved to '$(print_green "$ENV_VARS_FILE")'."
echo "To load the variables, run: $(print_green "source $ENV_VARS_FILE")"
