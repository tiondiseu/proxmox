#!/bin/bash
set -euo pipefail

# Home Bootstrap Script - Sets up WireGuard client and routing
# Usage: bash home-bootstrap.sh --vps-ip X.X.X.X --vps-pub "KEY" [options]

# Default values
VPS_IP=""
VPS_PUBLIC_KEY=""
WG_PORT=51820
HOME_IP="10.99.0.2/24"
LAN_IF="vmbr0"
LAN_CIDR="192.168.50.0/24"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --vps-ip)
            VPS_IP="$2"
            shift 2
            ;;
        --vps-pub)
            VPS_PUBLIC_KEY="$2"
            shift 2
            ;;
        --wg-port)
            WG_PORT="$2"
            shift 2
            ;;
        --home-ip)
            HOME_IP="$2"
            shift 2
            ;;
        --lan-if)
            LAN_IF="$2"
            shift 2
            ;;
        --lan-cidr)
            LAN_CIDR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option $1"
            echo "Usage: $0 --vps-ip X.X.X.X --vps-pub \"KEY\" [--wg-port 51820] [--home-ip 10.99.0.2/24] [--lan-if vmbr0] [--lan-cidr 192.168.50.0/24]"
            exit 1
            ;;
    esac
done

if [[ -z "$VPS_IP" || -z "$VPS_PUBLIC_KEY" ]]; then
    echo "Error: --vps-ip and --vps-pub are required"
    echo "Usage: $0 --vps-ip X.X.X.X --vps-pub \"KEY\" [options]"
    exit 1
fi

echo "🏠 Home Bootstrap Script Starting..."
echo "VPS IP: $VPS_IP"
echo "WireGuard Port: $WG_PORT"
echo "Home WG IP: $HOME_IP"
echo "LAN Interface: $LAN_IF"
echo "LAN CIDR: $LAN_CIDR"

# Detect if we're on Proxmox or regular Linux
if command -v pveversion &> /dev/null; then
    echo "✅ Detected Proxmox host"
    IS_PROXMOX=true
else
    echo "✅ Detected regular Linux system"
    IS_PROXMOX=false
fi

# Update system and install WireGuard
echo "📦 Installing WireGuard..."
if [[ "$IS_PROXMOX" == true ]]; then
    # Proxmox-specific package installation
    apt update
    apt install -y wireguard-tools
else
    # Regular Ubuntu/Debian
    apt update
    apt install -y wireguard wireguard-tools
fi

# Generate WireGuard keys
echo "🔑 Generating WireGuard keys..."
HOME_PRIVATE_KEY=$(wg genkey)
HOME_PUBLIC_KEY=$(echo "$HOME_PRIVATE_KEY" | wg pubkey)

# Detect actual LAN interface if vmbr0 doesn't exist
if ! ip link show "$LAN_IF" &> /dev/null; then
    echo "⚠️  Interface $LAN_IF not found, detecting primary interface..."
    # Find the interface with a default route
    NEW_LAN_IF=$(ip route | grep '^default' | head -1 | awk '{print $5}')
    if [[ -n "$NEW_LAN_IF" ]]; then
        echo "✅ Using interface: $NEW_LAN_IF"
        LAN_IF="$NEW_LAN_IF"
    else
        echo "❌ Could not detect primary network interface"
        exit 1
    fi
fi

# Auto-detect LAN CIDR if not specified correctly
if [[ "$LAN_CIDR" == "192.168.50.0/24" ]]; then
    echo "🔍 Auto-detecting LAN CIDR..."
    DETECTED_CIDR=$(ip route | grep "$LAN_IF" | grep -E '192\.168\.|10\.|172\.' | head -1 | awk '{print $1}' | grep -v default || echo "")
    if [[ -n "$DETECTED_CIDR" && "$DETECTED_CIDR" != *"/32" ]]; then
        LAN_CIDR="$DETECTED_CIDR"
        echo "✅ Detected LAN CIDR: $LAN_CIDR"
    else
        echo "⚠️  Could not auto-detect LAN CIDR, using default: $LAN_CIDR"
    fi
fi

# Create WireGuard configuration
echo "⚙️ Creating WireGuard configuration..."
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = $HOME_IP
PrivateKey = $HOME_PRIVATE_KEY
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = ip link set %i mtu 1420
# NAT so LAN services don't need routes back to 10.99.0.0/24
PostUp = iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o $LAN_IF -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -o $LAN_IF -j ACCEPT
PostUp = iptables -A FORWARD -i $LAN_IF -o %i -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -s 10.99.0.0/24 -o $LAN_IF -j MASQUERADE 2>/dev/null || true
PreDown = iptables -D FORWARD -i %i -o $LAN_IF -j ACCEPT 2>/dev/null || true
PreDown = iptables -D FORWARD -i $LAN_IF -o %i -j ACCEPT 2>/dev/null || true

[Peer]
PublicKey = $VPS_PUBLIC_KEY
Endpoint = $VPS_IP:$WG_PORT
AllowedIPs = 10.99.0.0/24
PersistentKeepalive = 25
EOF

# Enable IP forwarding permanently
echo "🌐 Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Start WireGuard
echo "🚀 Starting WireGuard..."
wg-quick up wg0

# Enable WireGuard service
systemctl enable wg-quick@wg0

# Test connectivity
echo "🧪 Testing WireGuard connectivity..."
if ping -c 2 -W 5 10.99.0.1 &> /dev/null; then
    echo "✅ WireGuard tunnel is working!"
else
    echo "⚠️  WireGuard tunnel test failed, but this might be normal if VPS peer isn't added yet"
fi

# Create helper script for testing services
cat > /root/test-service.sh << 'EOF'
#!/bin/bash
# Test if a service is reachable through the tunnel
# Usage: bash test-service.sh <local_ip> <port>

LOCAL_IP="$1"
PORT="$2"

if [[ -z "$LOCAL_IP" || -z "$PORT" ]]; then
    echo "Usage: $0 <local_ip> <port>"
    echo "Example: $0 192.168.50.10 8080"
    exit 1
fi

echo "Testing service at $LOCAL_IP:$PORT through tunnel..."

# Test from VPS perspective (simulate the reverse proxy)
if command -v nc &> /dev/null; then
    if timeout 5 nc -zv "$LOCAL_IP" "$PORT" 2>/dev/null; then
        echo "✅ Service is reachable at $LOCAL_IP:$PORT"
    else
        echo "❌ Service is NOT reachable at $LOCAL_IP:$PORT"
    fi
else
    echo "⚠️  netcat not available for testing"
fi
EOF

chmod +x /root/test-service.sh

echo ""
echo "🎉 Home Bootstrap Complete!"
echo ""
echo "📋 Configuration Summary:"
echo "- Home WireGuard IP: $HOME_IP"
echo "- LAN Interface: $LAN_IF"
echo "- LAN CIDR: $LAN_CIDR"
echo "- WireGuard Status:"
wg show 2>/dev/null || echo "  (Interface not yet connected to peer)"
echo ""
echo "🔑 Home WireGuard Public Key:"
echo "$HOME_PUBLIC_KEY"
echo ""
echo "📝 Next Step - Run this command on your VPS:"
echo ""
echo "bash /root/add-home-peer.sh \"$HOME_PUBLIC_KEY\" \"$LAN_CIDR\""
echo ""
echo "🔧 After adding the peer on VPS, test connectivity:"
echo "ping 10.99.0.1"
echo ""
echo "🌐 To expose a service (example):"
echo "1. In NPM web UI, add Proxy Host:"
echo "   - Domain: app.yourdomain.com"
echo "   - Forward to: http://192.168.X.Y:PORT"
echo "   - Enable SSL (Let's Encrypt)"
echo ""
echo "2. Test local service reachability:"
echo "bash /root/test-service.sh 192.168.X.Y PORT"
echo ""
echo "🎯 Common service examples:"
echo "- Jellyfin: usually on port 8096"
echo "- Nextcloud: usually on port 80/443"
echo "- Home Assistant: usually on port 8123"
echo "- Plex: usually on port 32400"
