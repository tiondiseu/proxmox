#!/bin/bash

# Proxmox VE Update and Upgrade Script
# This script fixes repository issues and updates a Proxmox VE system

set -e

echo "================================"
echo "Proxmox VE Update & Upgrade Tool"
echo "================================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root"
   exit 1
fi

# Detect Proxmox version
if [ -f /etc/pve-release ]; then
    PVE_VERSION=$(cat /etc/pve-release | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+')
    echo "Detected Proxmox VE version: $PVE_VERSION"
else
    echo "Warning: Could not detect Proxmox VE version"
fi

echo
echo "Step 1: Backing up current repository configuration..."

# Backup existing sources
cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
if [ -d /etc/apt/sources.list.d ]; then
    cp -r /etc/apt/sources.list.d /etc/apt/sources.list.d.backup.$(date +%Y%m%d_%H%M%S)
fi

echo "Repository configuration backed up successfully"

echo
echo "Step 2: Configuring Proxmox repositories..."

# Disable enterprise repositories by commenting them out
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list
    echo "Disabled enterprise PVE repository"
fi

if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/ceph.list
    echo "Disabled enterprise Ceph repository"
fi

# Add no-subscription repository if not already present
if ! grep -q "pve-no-subscription" /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    echo "Added no-subscription PVE repository"
fi

# Ensure Debian repositories are properly configured
cat > /etc/apt/sources.list << EOF
# Debian Bookworm repositories
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

echo "Configured Debian base repositories"

echo
echo "Step 3: Adding Proxmox GPG keys..."

# Download and add Proxmox GPG key
wget -O /tmp/proxmox-release-bookworm.gpg "http://download.proxmox.com/debian/proxmox-release-bookworm.gpg" 2>/dev/null || {
    echo "Warning: Could not download GPG key via wget, trying curl..."
    curl -fsSL -o /tmp/proxmox-release-bookworm.gpg "http://download.proxmox.com/debian/proxmox-release-bookworm.gpg" || {
        echo "Error: Could not download Proxmox GPG key"
        exit 1
    }
}

cp /tmp/proxmox-release-bookworm.gpg /etc/apt/trusted.gpg.d/
echo "Proxmox GPG key installed"

echo
echo "Step 4: Updating package lists..."

# Clean package cache and update
apt clean
apt update

echo
echo "Step 5: Upgrading system packages..."

# Perform upgrade with automatic yes to prompts
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y

echo
echo "Step 6: Cleaning up..."

# Remove downloaded packages and clean cache
apt autoremove -y
apt autoclean

echo
echo "Step 7: System information..."

# Display current versions
echo "Current Proxmox VE version:"
pveversion 2>/dev/null || echo "PVE version command not available"

echo
echo "Kernel version:"
uname -r

echo
echo "Available disk space:"
df -h / | tail -1

echo
echo "================================"
echo "Update completed successfully!"
echo "================================"
echo
echo "Recommendations:"
echo "- Reboot the system if kernel was updated"
echo "- Check Proxmox web interface is accessible"
echo "- Review any service status if needed"
echo
echo "To reboot now, run: reboot"
