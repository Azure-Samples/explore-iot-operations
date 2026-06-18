#!/bin/bash

# ============================================================================
# Azure IoT Operations - Cleanup Script
# ============================================================================
# This script completely removes all components installed by linux_installer.sh
# 
# WARNING: This will delete:
#   - K3s Kubernetes cluster and ALL data
#   - kubectl, Helm, and all Kubernetes tools
#   - Optional tools (k9s, mosquitto-clients, etc.)
#   - All configuration files and logs
#   - All deployed applications and data
#
# Requirements:
#   - Run on the same edge device where linux_installer.sh was executed
#   - Non-root user with sudo privileges
#
# Usage:
#   ./linux_aio_cleanup.sh
#   ./linux_aio_cleanup.sh --force (skip confirmation)
#
# Author: Azure IoT Operations Team
# Date: January 2026
# Version: 1.0.0
# ============================================================================

set -e
set -o pipefail

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/linux_aio_cleanup_$(date +'%Y%m%d_%H%M%S').log"
FORCE_CLEANUP=false

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    echo "============================================================================"
    echo "Azure IoT Operations - Cleanup Script"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started: $(date)"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

# ============================================================================
# PARSE ARGUMENTS
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_CLEANUP=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Usage: ./linux_aio_cleanup.sh [OPTIONS]

Completely removes all Azure IoT Operations components from this edge device.

Options:
  --force    Skip confirmation prompt
  --help     Show this help message

WARNING: This will permanently delete:
  - K3s Kubernetes cluster and ALL data
  - kubectl, Helm, and all Kubernetes tools  
  - Optional tools (k9s, mosquitto-clients)
  - All configuration files and logs
  - All deployed applications and data

Examples:
  # Interactive cleanup (with confirmation)
  ./linux_aio_cleanup.sh

  # Force cleanup (no confirmation)
  ./linux_aio_cleanup.sh --force
EOF
    exit 0
}

# ============================================================================
# CONFIRMATION
# ============================================================================

confirm_cleanup() {
    if [ "$FORCE_CLEANUP" = "true" ]; then
        warn "Force mode enabled - skipping confirmation"
        return 0
    fi

    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                        ⚠️  WARNING  ⚠️                         ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}This script will PERMANENTLY DELETE:${NC}"
    echo ""
    echo "  • K3s Kubernetes cluster and ALL pod data"
    echo "  • All container images and volumes"
    echo "  • kubectl, Helm, and Kubernetes tools"
    echo "  • Optional tools (k9s, mosquitto-clients)"
    echo "  • CSI Secret Store and Azure providers"
    echo "  • All deployed applications (edgemqttsim, etc.)"
    echo "  • Configuration files and cluster data"
    echo "  • Installation logs"
    echo ""
    echo -e "${RED}THIS CANNOT BE UNDONE!${NC}"
    echo ""
    
    read -p "Are you absolutely sure you want to continue? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo ""
        info "Cleanup cancelled by user"
        exit 0
    fi
    
    echo ""
    warn "Starting cleanup in 5 seconds... Press Ctrl+C to abort"
    sleep 5
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

cleanup_k3s() {
    log "Removing K3s Kubernetes cluster..."
    
    if ! command -v k3s &> /dev/null; then
        info "K3s not installed, skipping"
        return 0
    fi
    
    # Stop K3s service
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        info "Stopping K3s service..."
        sudo systemctl stop k3s || warn "Failed to stop K3s service"
    fi
    
    # Run K3s uninstall script
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        info "Running K3s uninstall script..."
        sudo /usr/local/bin/k3s-uninstall.sh || warn "K3s uninstall script failed"
    fi
    
    # Remove K3s directories
    info "Removing K3s directories..."
    sudo rm -rf /etc/rancher/k3s
    sudo rm -rf /var/lib/rancher/k3s
    sudo rm -rf /var/lib/rancher
    
    success "K3s removed"
}

cleanup_kubectl() {
    log "Removing kubectl..."
    
    if ! command -v kubectl &> /dev/null; then
        info "kubectl not installed, skipping"
        return 0
    fi
    
    # Remove kubectl binary
    sudo rm -f /usr/local/bin/kubectl
    
    # Remove kubeconfig
    rm -rf ~/.kube
    
    success "kubectl removed"
}

cleanup_helm() {
    log "Removing Helm..."
    
    if ! command -v helm &> /dev/null; then
        info "Helm not installed, skipping"
        return 0
    fi
    
    # Remove Helm binary
    sudo rm -f /usr/local/bin/helm
    
    # Remove Helm cache and config
    rm -rf ~/.cache/helm
    rm -rf ~/.config/helm
    
    success "Helm removed"
}

cleanup_optional_tools() {
    log "Removing optional tools..."
    
    # Remove k9s
    if command -v k9s &> /dev/null; then
        info "Removing k9s..."
        sudo rm -f /usr/local/bin/k9s
        rm -rf ~/.config/k9s
    fi
    
    # Remove mosquitto-clients
    if command -v mosquitto_sub &> /dev/null; then
        info "Removing mosquitto-clients..."
        sudo apt-get remove -y mosquitto-clients || warn "Failed to remove mosquitto-clients"
    fi
    
    success "Optional tools removed"
}

cleanup_config_files() {
    log "Removing configuration files..."
    
    # Remove cluster_info.json
    if [ -f "$SCRIPT_DIR/cluster_info.json" ]; then
        info "Removing cluster_info.json..."
        rm -f "$SCRIPT_DIR/cluster_info.json"
    fi
    
    # Remove deployment summaries
    rm -f "$SCRIPT_DIR"/deployment_summary*.json
    
    success "Configuration files removed"
}

cleanup_logs() {
    log "Cleaning up log files..."
    
    # Ask user if they want to keep logs
    if [ "$FORCE_CLEANUP" != "true" ]; then
        read -p "Remove installation log files? (y/n): " remove_logs
        if [ "$remove_logs" != "y" ]; then
            info "Keeping log files"
            return 0
        fi
    fi
    
    # Remove installer logs (but keep current cleanup log)
    find "$SCRIPT_DIR" -name "linux_installer_*.log" -type f -delete 2>/dev/null || true
    find "$SCRIPT_DIR" -name "external_configurator_*.log" -type f -delete 2>/dev/null || true
    
    # Remove old cleanup logs (but keep the current one being written)
    local current_log_basename=$(basename "$LOG_FILE")
    find "$SCRIPT_DIR" -name "linux_aio_cleanup_*.log" -type f ! -name "$current_log_basename" -delete 2>/dev/null || true
    
    success "Log files cleaned"
    info "Note: Current cleanup log preserved: $current_log_basename"
}

cleanup_container_runtime() {
    log "Cleaning up container runtime..."
    
    # Remove containerd data (if it exists separately)
    sudo rm -rf /var/lib/containerd
    
    # Remove cni plugins
    sudo rm -rf /opt/cni
    sudo rm -rf /etc/cni
    
    success "Container runtime cleaned"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Setup logging
    setup_logging
    
    # Show warning and get confirmation
    confirm_cleanup
    
    echo ""
    log "Starting cleanup process..."
    echo ""
    
    # Execute cleanup in order
    cleanup_k3s
    cleanup_kubectl
    cleanup_helm
    cleanup_optional_tools
    cleanup_container_runtime
    cleanup_config_files
    cleanup_logs
    
    # Final summary
    echo ""
    echo "============================================================================"
    log "Cleanup completed successfully!"
    echo "============================================================================"
    echo ""
    echo "The following components have been removed:"
    echo "  ✓ K3s Kubernetes cluster"
    echo "  ✓ kubectl and Helm"
    echo "  ✓ Optional tools (k9s, mosquitto-clients)"
    echo "  ✓ Configuration files"
    echo "  ✓ Container runtime data"
    echo ""
    echo "Log file saved to: $LOG_FILE"
    echo ""
    info "Your system has been cleaned. You can now run linux_installer.sh to reinstall."
    echo ""
}

# Trap to handle script interruption
trap 'echo ""; error "Cleanup interrupted by user"' INT

# Run main function
main "$@"
