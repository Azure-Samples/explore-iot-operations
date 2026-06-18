#!/bin/bash

# ============================================================================
# Azure IoT Operations - Worker Node Installer
# ============================================================================
# This script installs K3s as a worker (agent) node and joins an existing cluster.
#
# Requirements:
#   - Ubuntu 24.04+ (22.04 may work)
#   - 8GB+ RAM (16GB recommended)
#   - 2+ CPUs
#   - Network connectivity to the server node
#   - Node token from the server
#
# Usage:
#   ./install_worker.sh --server <SERVER_IP> --token <TOKEN>
#   ./install_worker.sh --server 172.25.129.151 --token K10abc123...
#
# To get the token from your server node:
#   sudo cat /var/lib/rancher/k3s/server/node-token
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
LOG_FILE="${SCRIPT_DIR}/install_worker_$(date +'%Y%m%d_%H%M%S').log"

# Parameters
SERVER_IP=""
SERVER_URL=""
NODE_TOKEN=""
NODE_NAME=""
DRY_RUN=false

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

setup_logging() {
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    echo "============================================================================"
    echo "Azure IoT Operations - Worker Node Installer"
    echo "============================================================================"
    echo "Log file: $LOG_FILE"
    echo "Started: $(date)"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

# ============================================================================
# HELP AND ARGUMENT PARSING
# ============================================================================

show_help() {
    cat << EOF
Azure IoT Operations - Worker Node Installer

This script installs K3s as a worker node and joins an existing cluster.

Usage: $0 [OPTIONS]

Required Options:
    --server IP         IP address of the K3s server node (e.g., 172.25.129.151)
    --token TOKEN       Node token from the server

Optional:
    --name NAME         Custom name for this worker node (default: hostname)
    --dry-run           Show what would be done without making changes
    --help              Show this help message

How to get the token (run on SERVER node):
    sudo cat /var/lib/rancher/k3s/server/node-token

Examples:
    # Join existing cluster
    ./install_worker.sh --server 172.25.129.151 --token K10abc123def456...

    # Join with custom node name
    ./install_worker.sh --server 172.25.129.151 --token K10abc123... --name worker-01

    # Dry run to verify settings
    ./install_worker.sh --server 172.25.129.151 --token K10abc123... --dry-run
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --server)
                SERVER_IP="$2"
                SERVER_URL="https://${SERVER_IP}:6443"
                shift 2
                ;;
            --token)
                NODE_TOKEN="$2"
                shift 2
                ;;
            --name)
                NODE_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
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
    
    # Validate required parameters
    if [ -z "$SERVER_IP" ]; then
        echo ""
        echo -e "${RED}ERROR: --server is required${NC}"
        echo ""
        echo "To get server IP, run on your server node:"
        echo "  hostname -I | awk '{print \$1}'"
        echo ""
        echo "Example:"
        echo "  ./install_worker.sh --server 172.25.129.151 --token <TOKEN>"
        echo ""
        exit 1
    fi
    
    if [ -z "$NODE_TOKEN" ]; then
        echo ""
        echo -e "${RED}ERROR: --token is required${NC}"
        echo ""
        echo "To get the token, run on your SERVER node:"
        echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
        echo ""
        echo "Example:"
        echo "  ./install_worker.sh --server $SERVER_IP --token K10abc123..."
        echo ""
        exit 1
    fi
    
    # Set default node name if not provided
    if [ -z "$NODE_NAME" ]; then
        NODE_NAME=$(hostname)
    fi
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_root() {
    log "Checking user privileges..."
    
    if [ "$EUID" -eq 0 ]; then
        error "Please do not run this script as root. Use sudo when prompted."
    fi
    
    if ! sudo -n true 2>/dev/null; then
        warn "This script requires sudo privileges. You may be prompted for your password."
        if ! sudo true; then
            error "Failed to obtain sudo privileges"
        fi
    fi
    
    success "User privileges validated"
}

check_system_requirements() {
    log "Checking system requirements..."
    
    # Check OS
    if [ ! -f /etc/os-release ]; then
        error "Cannot detect OS. This script requires Ubuntu."
    fi
    
    source /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        error "This script requires Ubuntu. Detected: $ID"
    fi
    success "OS: Ubuntu $VERSION_ID"
    
    # Check CPU cores (worker needs less than server)
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        warn "CPU cores: $cpu_cores (2+ recommended for worker nodes)"
    else
        success "CPU cores: $cpu_cores"
    fi
    
    # Check RAM (worker needs less than server)
    local total_mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_mem_gb" -lt 8 ]; then
        warn "RAM: ${total_mem_gb}GB (8GB+ recommended for worker nodes)"
    else
        success "RAM: ${total_mem_gb}GB"
    fi
    
    # Check disk space
    local disk_avail_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$disk_avail_gb" -lt 30 ]; then
        warn "Available disk space: ${disk_avail_gb}GB (30GB+ recommended)"
    else
        success "Disk space: ${disk_avail_gb}GB available"
    fi
    
    success "System requirements check completed"
}

check_network_connectivity() {
    log "Checking network connectivity to server..."
    
    # Check if we can reach the server
    if ! ping -c 1 -W 5 "$SERVER_IP" &> /dev/null; then
        error "Cannot reach server at $SERVER_IP. Check network connectivity."
    fi
    success "Server $SERVER_IP is reachable"
    
    # Check if port 6443 is open
    if command -v nc &> /dev/null; then
        if ! nc -z -w 5 "$SERVER_IP" 6443 &> /dev/null; then
            warn "Cannot connect to port 6443 on $SERVER_IP"
            echo "This could mean:"
            echo "  - K3s server is not running"
            echo "  - Firewall is blocking the port"
            echo "  - Wrong server IP"
            echo ""
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error "Installation aborted"
            fi
        else
            success "Port 6443 is accessible on server"
        fi
    else
        info "netcat not installed, skipping port check"
    fi
    
    # Check internet connectivity (for downloading K3s)
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "No internet connectivity. Required to download K3s."
    fi
    success "Internet connectivity verified"
}

check_existing_k3s() {
    log "Checking for existing K3s installation..."
    
    if command -v k3s &> /dev/null; then
        if sudo systemctl is-active --quiet k3s-agent 2>/dev/null; then
            warn "K3s agent is already running on this machine"
            read -p "Remove existing installation and reinstall? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_k3s
            else
                error "Cannot proceed with existing K3s installation"
            fi
        elif sudo systemctl is-active --quiet k3s 2>/dev/null; then
            error "This machine is running a K3s SERVER. Cannot install as worker."
        fi
    fi
    
    success "No conflicting K3s installation found"
}

# ============================================================================
# INSTALLATION
# ============================================================================

cleanup_k3s() {
    log "Cleaning up existing K3s installation..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would run K3s cleanup"
        return 0
    fi
    
    # Run agent uninstall script if it exists
    if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        sudo /usr/local/bin/k3s-agent-uninstall.sh || warn "Agent uninstall script failed"
    fi
    
    # Run server uninstall script if it exists
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        sudo /usr/local/bin/k3s-uninstall.sh || warn "Server uninstall script failed"
    fi
    
    # Manual cleanup
    sudo systemctl stop k3s-agent 2>/dev/null || true
    sudo rm -rf /var/lib/rancher/k3s
    sudo rm -rf /etc/rancher/k3s
    sudo rm -f /usr/local/bin/k3s*
    
    success "K3s cleanup completed"
}

install_k3s_agent() {
    log "Installing K3s agent (worker node)..."
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}K3s Agent Installation${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "Server URL: $SERVER_URL"
    echo "Node Name:  $NODE_NAME"
    echo "Token:      ${NODE_TOKEN:0:20}..."
    echo ""
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would install K3s agent with:"
        info "  K3S_URL=$SERVER_URL"
        info "  K3S_TOKEN=<token>"
        info "  Node name: $NODE_NAME"
        return 0
    fi
    
    # Install K3s as agent
    curl -sfL https://get.k3s.io | K3S_URL="$SERVER_URL" K3S_TOKEN="$NODE_TOKEN" sh -s - agent \
        --node-name "$NODE_NAME"
    
    # Wait for agent to start
    log "Waiting for K3s agent to start..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if sudo systemctl is-active --quiet k3s-agent; then
            success "K3s agent is running"
            break
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            error "K3s agent failed to start after $max_attempts attempts"
        fi
        
        info "Waiting for K3s agent... (attempt $attempt/$max_attempts)"
        sleep 5
    done
    
    success "K3s agent installed and running"
}

# ============================================================================
# VERIFICATION
# ============================================================================

verify_cluster_join() {
    log "Verifying cluster join..."
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would verify cluster join"
        return 0
    fi
    
    # Check agent service status
    if sudo systemctl is-active --quiet k3s-agent; then
        success "K3s agent service is running"
    else
        warn "K3s agent service is not active"
        echo "Check logs: sudo journalctl -u k3s-agent -n 50"
    fi
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Verification Instructions${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "To verify this node joined the cluster, run on the SERVER node:"
    echo ""
    echo "  kubectl get nodes"
    echo ""
    echo "You should see this worker node in the list:"
    echo ""
    echo "  NAME          STATUS   ROLES                  AGE   VERSION"
    echo "  <server>      Ready    control-plane,master   Xd    v1.xx.x"
    echo "  $NODE_NAME    Ready    <none>                 Xs    v1.xx.x"
    echo ""
    echo "If the node shows 'NotReady', wait a few minutes for it to sync."
    echo ""
}

# ============================================================================
# COMPLETION
# ============================================================================

display_completion() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}Worker Node Installation Completed!${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
    echo "This node ($NODE_NAME) has been added to the cluster."
    echo ""
    echo "Server: $SERVER_URL"
    echo ""
    echo -e "${GREEN}Management Commands (run on SERVER node):${NC}"
    echo ""
    echo "  # List all nodes"
    echo "  kubectl get nodes"
    echo ""
    echo "  # See pods running on this worker"
    echo "  kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE_NAME"
    echo ""
    echo "  # Label this node (for workload targeting)"
    echo "  kubectl label node $NODE_NAME node-role.kubernetes.io/worker=true"
    echo ""
    echo -e "${GREEN}Worker Node Commands (run here):${NC}"
    echo ""
    echo "  # Check agent status"
    echo "  sudo systemctl status k3s-agent"
    echo ""
    echo "  # View agent logs"
    echo "  sudo journalctl -u k3s-agent -f"
    echo ""
    echo "  # Restart agent"
    echo "  sudo systemctl restart k3s-agent"
    echo ""
    echo -e "${YELLOW}Note:${NC} kubectl is not configured on worker nodes by default."
    echo "All cluster management should be done from the server node."
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}NOTE: This was a DRY-RUN. No changes were made.${NC}"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Setup logging
    setup_logging
    
    log "Starting K3s Worker Node Installation"
    
    if [ "$DRY_RUN" = "true" ]; then
        warn "DRY-RUN MODE: No changes will be made"
    fi
    
    echo ""
    
    # Pre-flight checks
    check_root
    check_system_requirements
    check_network_connectivity
    check_existing_k3s
    
    # Installation
    install_k3s_agent
    
    # Verification
    verify_cluster_join
    
    # Completion
    display_completion
    
    log "Worker node installation completed successfully!"
}

# Handle interruption
trap 'error "Script interrupted by user"' INT

# Run main
main "$@"
