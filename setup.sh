#!/usr/bin/env bash
# NixOS Bootstrap Script for Tailscale SSH + VS Code Remote Editing
# Usage: curl -fsSL https://raw.githubusercontent.com/bentrol1/nixos-bootstrap/main/setup.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running on NixOS
if [[ ! -f /etc/NIXOS ]]; then
    error "This script must be run on NixOS"
fi

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. Run as a regular user with sudo access."
fi

log "Starting NixOS bootstrap for Tailscale SSH + VS Code Remote editing..."

# Create backup directory
BACKUP_DIR="/tmp/nixos-bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup current configuration
if [[ -f /etc/nixos/configuration.nix ]]; then
    log "Backing up current configuration to $BACKUP_DIR"
    sudo cp /etc/nixos/configuration.nix "$BACKUP_DIR/"
fi

# Create the bootstrap module
log "Creating bootstrap module..."
sudo tee /etc/nixos/bootstrap-module.nix > /dev/null << 'EOF'
{ config, pkgs, lib, ... }:

{
  # Tailscale configuration
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };

  # QEMU Guest Agent (for VMs) - enables better VM integration
  services.qemuGuest.enable = lib.mkDefault true;

  # SSH service configuration for remote access
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = lib.mkDefault true;
      PermitRootLogin = lib.mkDefault "prohibit-password";
      X11Forwarding = false;
      PrintMotd = false;
    };
  };

  # Enable nix-ld for VS Code Remote SSH compatibility
  # This allows VS Code to run its Node.js server and extensions
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Core libraries needed for VS Code Remote
    stdenv.cc.cc.lib
    zlib
    openssl
    curl
    expat
    fontconfig
    freetype
    glib
    icu
    libdrm
    libGL
    mesa
    nspr
    nss
    xorg.libX11
    xorg.libxcb
    # Additional libraries for common extensions
    python3
    nodejs_18
  ];

  # Firewall configuration
  networking.firewall = {
    enable = true;
    # Trust Tailscale interface
    trustedInterfaces = [ "tailscale0" ];
    # Allow SSH
    allowedTCPPorts = [ 22 ];
    # Allow Tailscale
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  # Network configuration
  networking.networkmanager.enable = lib.mkDefault true;

  # Essential system packages
  environment.systemPackages = with pkgs; [
    tailscale
    wget
    curl
    git
    vim
    htop
    tree
    tmux
    # Required for VS Code Remote
    nodejs_18
    python3
  ];

  # Enable flakes and new nix command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Additional configuration to help VS Code Remote work
  environment.variables = {
    # Ensure VS Code can find Node.js
    NODE_PATH = "${pkgs.nodejs_18}/lib/node_modules";
  };

  # Create compatibility symlinks - NixOS 25.05 compatible
  # Using environment.extraInit instead of removed activation scripts
  environment.extraInit = ''
    # Create compatibility symlinks for VS Code Remote
    if [ ! -d /usr/bin ]; then
      mkdir -p /usr/bin
    fi
    if [ ! -e /usr/bin/node ]; then
      ln -sf ${pkgs.nodejs_18}/bin/node /usr/bin/node
    fi
    if [ ! -e /usr/bin/python3 ]; then
      ln -sf ${pkgs.python3}/bin/python3 /usr/bin/python3
    fi
  '';
}
EOF

# Update configuration.nix to include the bootstrap module
log "Updating configuration.nix to include bootstrap module..."

# Check if configuration.nix already imports the bootstrap module
if ! sudo grep -q "bootstrap-module.nix" /etc/nixos/configuration.nix; then
    
    # Create a more robust approach to add the import
    # This handles the multiple import sections in NixOS 25.05
    python3 << 'PYTHON_EOF'
import re
import sys

# Read the configuration file
with open('/etc/nixos/configuration.nix', 'r') as f:
    content = f.read()

# Check if we already have the import
if 'bootstrap-module.nix' in content:
    print("bootstrap-module.nix already imported")
    sys.exit(0)

# Pattern to find imports sections
imports_pattern = r'imports\s*=\s*\[\s*(.*?)\s*\];'
matches = list(re.finditer(imports_pattern, content, re.DOTALL))

if matches:
    # Add to the first imports section
    first_match = matches[0]
    imports_content = first_match.group(1).strip()
    
    if imports_content:
        # Add our module to existing imports
        new_imports = imports_content + '\n    ./bootstrap-module.nix'
    else:
        # First import in empty list
        new_imports = '\n    ./bootstrap-module.nix\n  '
    
    new_content = (
        content[:first_match.start(1)] +
        new_imports +
        content[first_match.end(1):]
    )
else:
    # No imports found, add at the beginning
    # Find the opening brace and add imports section
    brace_match = re.search(r'^{', content, re.MULTILINE)
    if brace_match:
        insert_pos = brace_match.end()
        new_content = (
            content[:insert_pos] +
            '\n  imports = [\n    ./bootstrap-module.nix\n  ];\n' +
            content[insert_pos:]
        )
    else:
        print("ERROR: Could not find opening brace in configuration.nix")
        sys.exit(1)

# Write the updated content
with open('/etc/nixos/configuration.nix', 'w') as f:
    f.write(new_content)

print("Added bootstrap-module.nix to imports")
PYTHON_EOF

    if [[ $? -eq 0 ]]; then
        log "Successfully added bootstrap-module.nix to configuration imports"
    else
        error "Failed to update configuration.nix"
    fi
else
    log "bootstrap-module.nix already imported"
fi

# Rebuild the system
log "Rebuilding NixOS configuration..."
if ! sudo nixos-rebuild switch; then
    error "Failed to rebuild NixOS configuration. Please check the configuration and try again."
fi

# Start and enable Tailscale
log "Starting Tailscale service..."
sudo systemctl enable --now tailscale

# Wait for Tailscale to be ready
sleep 3

# Generate Tailscale auth URL with SSH enabled
log "Configuring Tailscale with SSH support..."
AUTH_URL=$(sudo tailscale up --ssh --reset 2>&1 | grep -o 'https://login\.tailscale\.com/[^[:space:]]*' || true)

if [[ -n "$AUTH_URL" ]]; then
    echo
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    TAILSCALE SETUP                           ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} Please visit the following URL to authenticate Tailscale:    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${YELLOW}$AUTH_URL${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} After authentication, you can use Tailscale SSH.            ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Wait for user to authenticate (optional)
    read -p "Press Enter after completing Tailscale authentication, or Ctrl+C to skip..."
    
    # Check if authenticated and get connection details
    if sudo tailscale status --json >/dev/null 2>&1; then
        TAILSCALE_IP=$(sudo tailscale ip -4 2>/dev/null || echo "Not available yet")
        TAILSCALE_HOSTNAME=$(hostname)
        
        echo
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                   BOOTSTRAP COMPLETE!                        ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} Your NixOS system is now configured with:                   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} ✓ Tailscale SSH enabled                                     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} ✓ VS Code Remote SSH compatibility                          ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} ✓ QEMU Guest Agent (for VMs)                               ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} ✓ Dynamic binary support (nix-ld)                          ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} Connection details:                                         ${GREEN}║${NC}"
        if [[ "$TAILSCALE_IP" != "Not available yet" ]]; then
            echo -e "${GREEN}║${NC} • Tailscale IP: ${YELLOW}$TAILSCALE_IP${NC}"
        fi
        echo -e "${GREEN}║${NC} • Hostname: ${YELLOW}$TAILSCALE_HOSTNAME${NC}"
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} To connect with VS Code:                                    ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC} 1. Install 'Remote - SSH' extension in VS Code              ${GREEN}║${NC}"
        if [[ "$TAILSCALE_IP" != "Not available yet" ]]; then
            echo -e "${GREEN}║${NC} 2. Connect using: ${YELLOW}$USER@$TAILSCALE_IP${NC}"
        fi
        echo -e "${GREEN}║${NC} 3. Or use hostname: ${YELLOW}$USER@$TAILSCALE_HOSTNAME${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
else
    warn "Could not generate Tailscale auth URL automatically."
    warn "Please run: sudo tailscale up --ssh"
    warn "Then visit the provided URL to authenticate."
fi

echo
log "Bootstrap completed successfully!"
log "Configuration backup saved to: $BACKUP_DIR"

# Show next steps and usage info
echo
echo -e "${BLUE}Next Steps:${NC}"
echo "1. Complete Tailscale authentication using the URL above"
echo "2. Install 'Remote - SSH' extension in VS Code"
echo "3. Add SSH connection in VS Code using your Tailscale IP or hostname"
echo "4. VS Code Remote editing will work seamlessly"
echo
echo -e "${BLUE}Configuration Details:${NC}"
echo "• All changes are in /etc/nixos/bootstrap-module.nix"
echo "• Original configuration backed up to $BACKUP_DIR"
echo "• To remove: edit /etc/nixos/configuration.nix and run 'sudo nixos-rebuild switch'"
echo
echo -e "${YELLOW}Note:${NC} This configuration enables VS Code Remote SSH editing support."
echo -e "${YELLOW}Note:${NC} The first connection may take a moment as VS Code sets up its remote environment."
