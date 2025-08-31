#!/bin/bash
set -euo pipefail

# VPS Bootstrap Script - Routed WireGuard + Reverse Proxy
# Usage: curl -fsSL https://your-repo/vps-bootstrap.sh | bash -s -- --domain yourdomain.com

DOMAIN=""
WG_PORT=51820
VPS_WG_IP="10.100.0.1/24"
HOME_WG_IP="10.100.0.2"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo "Error: --domain is required"
    exit 1
fi

echo "🚀 Bootstrapping VPS for domain: $DOMAIN"

# Update system
echo "📦 Updating system..."
apt update && apt upgrade -y
apt install -y wireguard iptables-persistent ufw curl

# Generate WireGuard keys
echo "🔑 Generating WireGuard keys..."
VPS_PRIVATE_KEY=$(wg genkey)
VPS_PUBLIC_KEY=$(echo "$VPS_PRIVATE_KEY" | wg pubkey)
HOME_PRIVATE_KEY=$(wg genkey)
HOME_PUBLIC_KEY=$(echo "$HOME_PRIVATE_KEY" | wg pubkey)

# Get VPS public IP
VPS_PUBLIC_IP=$(curl -s ifconfig.me)

# Configure WireGuard on VPS
echo "⚙️ Creating VPS WireGuard configuration..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $VPS_PRIVATE_KEY
Address = $VPS_WG_IP
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = $HOME_PUBLIC_KEY
AllowedIPs = 10.100.0.2/32
EOF

# Configure firewall BEFORE starting Docker
echo "🔥 Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $WG_PORT/udp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Enable IP forwarding
echo "🌐 Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Start WireGuard
echo "🔗 Starting WireGuard..."
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Install Docker (after firewall setup)
echo "🐳 Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
systemctl enable docker
systemctl start docker

# Wait for Docker to fully initialize
sleep 5

# Install Nginx Proxy Manager
echo "🔧 Setting up Nginx Proxy Manager..."
mkdir -p /opt/nginx-proxy-manager
cd /opt/nginx-proxy-manager

cat > docker-compose.yml << EOF
version: '3.8'
services:
  nginx-proxy-manager:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
EOF

# Start Nginx Proxy Manager
docker-compose up -d

echo ""
echo "✅ VPS Setup Complete!"
echo ""
echo "📋 Connection Details:"
echo "VPS Public IP: $VPS_PUBLIC_IP"
echo "VPS WireGuard IP: 10.100.0.1"
echo "Home WireGuard IP: 10.100.0.2"
echo "Nginx Proxy Manager: http://$VPS_PUBLIC_IP:81"
echo "  Default login: admin@example.com / changeme"
echo ""
echo "🏠 Run this on your home edge VM/container:"
echo "curl -fsSL https://your-repo/home-bootstrap.sh | bash -s -- \\"
echo "  --vps-ip $VPS_PUBLIC_IP \\"
echo "  --vps-port $WG_PORT \\"
echo "  --vps-key '$VPS_PUBLIC_KEY' \\"
echo "  --home-key '$HOME_PRIVATE_KEY'"
echo ""
echo "📖 Next steps:"
echo "1. Run the home bootstrap script"
echo "2. Configure proxy rules in NPM to forward to 10.100.0.2:PORT"
echo "3. Point your domain DNS to $VPS_PUBLIC_IP"
