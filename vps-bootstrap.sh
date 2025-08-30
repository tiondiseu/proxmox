#!/bin/bash
set -euo pipefail

# VPS Bootstrap Script - Sets up WireGuard + Nginx Proxy Manager
# Usage: bash vps-bootstrap.sh --domain example.com [--wg-port 51820] [--npm-port 81]

# Default values
WG_PORT=51820
NPM_PORT=81
DOMAIN=""
VPS_PUBLIC_IP=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --wg-port)
            WG_PORT="$2"
            shift 2
            ;;
        --npm-port)
            NPM_PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option $1"
            echo "Usage: $0 --domain example.com [--wg-port 51820] [--npm-port 81]"
            exit 1
            ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo "Error: --domain is required"
    echo "Usage: $0 --domain example.com [--wg-port 51820] [--npm-port 81]"
    exit 1
fi

echo "🚀 VPS Bootstrap Script Starting..."
echo "Domain: $DOMAIN"
echo "WireGuard Port: $WG_PORT"
echo "NPM Web UI Port: $NPM_PORT"

# Detect VPS public IP
echo "🔍 Detecting VPS public IP..."
VPS_PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || echo "")
if [[ -z "$VPS_PUBLIC_IP" ]]; then
    echo "❌ Could not detect public IP. Please check your connection."
    exit 1
fi
echo "✅ Detected VPS Public IP: $VPS_PUBLIC_IP"

# Update system
echo "📦 Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "📦 Installing required packages..."
apt install -y curl docker.io docker-compose wireguard-tools ufw iptables-persistent

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Add current user to docker group (if not root)
if [[ $EUID -ne 0 ]]; then
    usermod -aG docker $USER
fi

# Generate WireGuard keys
echo "🔑 Generating WireGuard keys..."
VPS_PRIVATE_KEY=$(wg genkey)
VPS_PUBLIC_KEY=$(echo "$VPS_PRIVATE_KEY" | wg pubkey)

# Create WireGuard configuration
echo "⚙️ Creating WireGuard configuration..."
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.99.0.1/24
ListenPort = $WG_PORT
PrivateKey = $VPS_PRIVATE_KEY
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = ip link set %i mtu 1420

# Peer will be added after home setup
EOF

# Enable WireGuard service
systemctl enable wg-quick@wg0

# Configure UFW firewall
echo "🔥 Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow $WG_PORT/udp
ufw allow $NPM_PORT/tcp
ufw --force enable

# Create Nginx Proxy Manager setup
echo "🔧 Setting up Nginx Proxy Manager..."
mkdir -p /opt/npm
cat > /opt/npm/docker-compose.yml << EOF
version: '3.8'
services:
  nginx-proxy-manager:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '$NPM_PORT:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      DISABLE_IPV6: 'true'
EOF

# Start Nginx Proxy Manager
cd /opt/npm
docker-compose up -d

# Enable IP forwarding permanently
echo "🌐 Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Create helper script to add peer
cat > /root/add-home-peer.sh << 'EOF'
#!/bin/bash
# Usage: bash add-home-peer.sh <HOME_PUBLIC_KEY> <HOME_LAN_CIDR>
HOME_PUB_KEY="$1"
HOME_LAN_CIDR="$2"

if [[ -z "$HOME_PUB_KEY" || -z "$HOME_LAN_CIDR" ]]; then
    echo "Usage: $0 <HOME_PUBLIC_KEY> <HOME_LAN_CIDR>"
    echo "Example: $0 ABC123def456... 192.168.50.0/24"
    exit 1
fi

# Add peer to WireGuard config
cat >> /etc/wireguard/wg0.conf << EOL

[Peer]
PublicKey = $HOME_PUB_KEY
AllowedIPs = 10.99.0.2/32, $HOME_LAN_CIDR
PersistentKeepalive = 25
EOL

# Restart WireGuard
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl restart wg-quick@wg0

echo "✅ Home peer added successfully!"
echo "WireGuard status:"
wg show
EOF

chmod +x /root/add-home-peer.sh

echo ""
echo "🎉 VPS Bootstrap Complete!"
echo ""
echo "📋 Setup Summary:"
echo "- VPS Public IP: $VPS_PUBLIC_IP"
echo "- WireGuard Port: $WG_PORT"
echo "- WireGuard VPS IP: 10.99.0.1/24"
echo "- Nginx Proxy Manager: http://$VPS_PUBLIC_IP:$NPM_PORT"
echo "  Default login: admin@example.com / changeme"
echo ""
echo "🔑 VPS WireGuard Public Key:"
echo "$VPS_PUBLIC_KEY"
echo ""
echo "📝 Next Step - Run this command on your Proxmox host:"
echo ""
echo "curl -fsSL https://raw.githubusercontent.com/tiondiseu/proxmox/main/home-bootstrap.sh | bash -s -- \\"
echo "  --vps-ip $VPS_PUBLIC_IP \\"
echo "  --wg-port $WG_PORT \\"
echo "  --home-ip 10.99.0.2/24 \\"
echo "  --lan-if vmbr0 \\"
echo "  --vps-pub \"$VPS_PUBLIC_KEY\" \\"
echo "  --lan-cidr 192.168.50.0/24"
echo ""
echo "⚠️  Important: Point your domain '$DOMAIN' A record to $VPS_PUBLIC_IP"
echo ""
echo "🔧 After home setup, you'll need to run on VPS:"
echo "bash /root/add-home-peer.sh \"<HOME_PUBLIC_KEY>\" \"192.168.50.0/24\""
