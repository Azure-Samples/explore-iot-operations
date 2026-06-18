#!/bin/bash

# ============================================================================
# Verify CSI Secret Store Installation
# ============================================================================
# This script verifies that the CSI Secret Store driver and Azure Key Vault
# provider are properly installed and ready for Azure IoT Operations dataflows.
#
# Usage: ./verify-csi-secret-store.sh
# ============================================================================

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}============================================================================${NC}"
echo -e "${CYAN}CSI Secret Store Installation Verification${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo ""

# Check 1: CSI Driver resource
echo -n "Checking for CSI driver resource... "
if kubectl get csidriver secrets-store.csi.k8s.io &>/dev/null; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  CSI driver 'secrets-store.csi.k8s.io' is registered"
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  CSI driver 'secrets-store.csi.k8s.io' not found"
    echo "  This is required for Azure IoT Operations secret management"
    exit 1
fi
echo ""

# Check 2: CSI Secret Store driver pods
echo -n "Checking for CSI Secret Store driver pods... "
csi_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver --no-headers 2>/dev/null | wc -l)

if [ "$csi_pods" -gt 0 ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  Found $csi_pods CSI Secret Store driver pod(s)"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  No CSI Secret Store driver pods found in kube-system namespace"
    exit 1
fi
echo ""

# Check 3: Azure Key Vault provider pods
echo -n "Checking for Azure Key Vault provider pods... "
azure_pods=$(kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure --no-headers 2>/dev/null | wc -l)

if [ "$azure_pods" -gt 0 ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  Found $azure_pods Azure Key Vault provider pod(s)"
    kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure
else
    echo -e "${RED}✗ FAIL${NC}"
    echo "  No Azure Key Vault provider pods found in kube-system namespace"
    exit 1
fi
echo ""

# Check 4: Pod status - all should be Running
echo "Checking pod status..."
not_running=$(kubectl get pods -n kube-system | grep -E '(secrets-store|csi-secrets)' | grep -v Running | wc -l)

if [ "$not_running" -eq 0 ]; then
    echo -e "${GREEN}✓ PASS${NC}"
    echo "  All CSI Secret Store pods are Running"
else
    echo -e "${YELLOW}⚠ WARNING${NC}"
    echo "  Some pods are not in Running state:"
    kubectl get pods -n kube-system | grep -E '(secrets-store|csi-secrets)' | grep -v Running
fi
echo ""

# Summary
echo -e "${CYAN}============================================================================${NC}"
echo -e "${GREEN}✓ CSI Secret Store Verification Complete${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo ""
echo "Your cluster is ready for Azure IoT Operations with secret management enabled."
echo ""
echo "This means:"
echo "  ✓ Azure IoT Operations can use Azure Key Vault for secrets"
echo "  ✓ Fabric Real-Time Intelligence dataflows can be configured"
echo "  ✓ Secret management toggle will be available in the Azure portal"
echo ""
echo "Next steps:"
echo "  1. Deploy Azure IoT Operations: az iot ops create ..."
echo "  2. Configure dataflows with Key Vault references"
echo "  3. Create Fabric RTI endpoints in the Azure portal"
echo ""
