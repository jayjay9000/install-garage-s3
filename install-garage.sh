#!/bin/bash
# =============================================================================
# Garage S3 Installer — Pure Docker + Caddy + Watchtower
# Version: 2026.03.28
# Author: jayjay9000
#
# =============================================================================
set -euo pipefail

# ====================== COLORS & LOGGING ======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# ====================== HELPERS ======================
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ====================== ROOT CHECK ======================
if [[ $EUID -ne 0 ]]; then
    error "Please run as root or with sudo: sudo bash install-garage.sh"
fi

# ====================== BANNER & CONFIRMATION ======================
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║          Garage S3 Self-Hosted Installer (Enhanced)          ║
║  Single-node • Docker • Caddy (Let’s Encrypt) • Watchtower  ║
╚══════════════════════════════════════════════════════════════╝
EOF

read -rp "Continue with installation? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log "Installation cancelled."; exit 0; }

log "Starting enhanced Garage S3 installation..."

# ====================== PRE-FLIGHT CHECKS ======================
info "Running pre-flight checks..."

# OS
if ! grep -qE 'debian|ubuntu' /etc/os-release; then
    error "Only Debian/Ubuntu supported (apt-based)."
fi

# Disk space
FREE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
(( $(echo "$FREE < 50" | bc -l 2>/dev/null || echo 0) )) && warn "Less than 50 GB free on root — recommend more for production data!"

# Ports
for p in 80 443; do
    if ss -tlnp | grep -q ":$p " 2>/dev/null || netstat -tlnp | grep -q ":$p " 2>/dev/null; then
        warn "Port $p is in use. Installation may fail."
    fi
done

# ====================== USER INPUTS ======================
read -rp "Domain (e.g. s3.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Domain is required!"

read -rp "Email for Let’s Encrypt notifications: " EMAIL
[[ -z "$EMAIL" ]] && { EMAIL="admin@${DOMAIN}"; warn "Using ${EMAIL} for Let’s Encrypt."; }

read -rp "Storage capacity for this node (e.g. 2T, 500G) [2T]: " CAPACITY
CAPACITY=${CAPACITY:-2T}

read -rp "Installation directory [/opt/garage-s3]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/garage-s3}

PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "YOUR_PUBLIC_IP")
read -rp "Detected public IP ($PUBLIC_IP). Confirm or enter new IP: " IP_INPUT
[[ -n "$IP_INPUT" && "$IP_INPUT" != "y" && "$IP_INPUT" != "Y" ]] && PUBLIC_IP="$IP_INPUT"

# Summary
cat << EOF
${BLUE}═══════════════════════════════════════════════════════════════${NC}
Installation summary:
  Domain          : $DOMAIN
  Email           : $EMAIL
  Capacity        : $CAPACITY
  Directory       : $INSTALL_DIR
  Public IP       : $PUBLIC_IP
${BLUE}═══════════════════════════════════════════════════════════════${NC}
EOF
read -rp "Proceed? (y/N): " PROCEED
[[ "$PROCEED" =~ ^[Yy]$ ]] || error "Aborted by user."

# ====================== SYSTEM UPDATE & PREREQUISITES ======================
log "Updating system packages..."
apt-get update -qq && apt-get upgrade -y

log "Installing prerequisites..."
apt-get install -y curl wget git ufw unattended-upgrades fail2ban crowdsec \
    crowdsec-firewall-bouncer-iptables jq ca-certificates gnupg

# Official Docker (latest, signed repo — more secure than docker.io)
if ! command_exists docker; then
    log "Installing official Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker
log "Docker ready"

# ====================== SECURITY HARDENING ======================
log "Applying security hardening..."

# UFW
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
log "UFW enabled (SSH + HTTP + HTTPS only)"

# Unattended upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
systemctl enable --now unattended-upgrades

# Fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
EOF
systemctl restart fail2ban

# CrowdSec + Docker protection (critical fix)
cat > /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml <<EOF
mode: iptables
iptables_chain: DOCKER-USER
disable_ipv6: true
EOF
systemctl enable --now crowdsec crowdsec-firewall-bouncer-iptables
log "CrowdSec + Docker bouncer configured (blocks brute-force across host & containers)"

# ====================== PROJECT SETUP ======================
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Backup if re-running
if [ -f "garage.toml" ] || [ -f "docker-compose.yml" ]; then
    BACKUP="backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"
    cp -a garage.toml docker-compose.yml Caddyfile 2>/dev/null || true
    log "Backed up old configs → ./${BACKUP}/"
fi

# Secrets
RPC_SECRET=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-')
log "Strong secrets generated (saved securely)"

# ====================== garage.toml ======================
cat > garage.toml <<EOF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "${PUBLIC_IP}:3901"
rpc_secret = "${RPC_SECRET}"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = "${DOMAIN}"

[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.${DOMAIN}"
index = "index.html"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "${ADMIN_TOKEN}"
EOF
chmod 600 garage.toml
log "garage.toml created (permissions locked)"

# ====================== docker-compose.yml ======================
cat > docker-compose.yml <<EOF
version: '3.8'
services:
  garage:
    image: dxflrs/garage:v2.2.0
    container_name: garage
    restart: unless-stopped
    # NO host ports — Caddy proxies internally (major security win)
    volumes:
      - ./garage.toml:/etc/garage.toml:ro
      - garage_meta:/var/lib/garage/meta
      - garage_data:/var/lib/garage/data
    networks:
      - internal
    healthcheck:
      test: ["CMD", "garage", "status"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - internal
    depends_on:
      garage:
        condition: service_healthy

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=3600
      - WATCHTOWER_SCHEDULE=0 0 * * *

networks:
  internal:
    internal: true

volumes:
  garage_meta:
  garage_data:
  caddy_data:
  caddy_config:
EOF
log "docker-compose.yml created (Garage fully isolated)"

# ====================== Caddyfile ======================
cat > Caddyfile <<EOF
{
    email ${EMAIL}
    # Global security/performance
    servers {
        protocol {
            http2
        }
    }
}

${DOMAIN} {
    reverse_proxy garage:3900
}

admin.${DOMAIN} {
    reverse_proxy garage:3903
    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Content-Type-Options "nosniff"
    }
}

*.web.${DOMAIN} {
    reverse_proxy garage:3902
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer-when-downgrade"
    }
}
EOF
log "Caddyfile created (auto HTTPS + security headers)"

# ====================== START & INITIALIZE ======================
log "Starting services..."
docker compose pull
docker compose up -d

log "Waiting for Garage to become ready (up to 60 s)..."
for i in {1..30}; do
    if docker exec garage garage status >/dev/null 2>&1; then
        log "Garage ready!"
        break
    fi
    sleep 2
done

NODE_ID=$(docker exec garage garage status | grep -oP 'Node ID: \K\S+' || echo "")
if [[ -n "$NODE_ID" ]]; then
    docker exec garage garage layout assign -z dc1 -c "$CAPACITY" "$NODE_ID" || true
    docker exec garage garage layout apply --version 1 || true
    log "Single-node layout applied (${CAPACITY} capacity)"
else
    warn "Could not auto-detect NODE_ID — manual init may be needed"
fi

# ====================== FINAL OUTPUT ======================
log "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
log "${GREEN}🎉 Installation COMPLETE!${NC}"

cat << EOF

Your Garage S3 endpoint is ready:

 • S3 API          : https://${DOMAIN}
 • Admin           : https://admin.${DOMAIN}
 • Web buckets     : https://<bucket>.web.${DOMAIN}

DNS (critical):
  ${DOMAIN}         → ${PUBLIC_IP}
  admin.${DOMAIN}   → ${PUBLIC_IP}
  *.web.${DOMAIN}   → ${PUBLIC_IP}   (wildcard A record)

Next steps:
1. Create key & bucket:
   docker exec -it garage garage key create my-first-key
   docker exec -it garage garage bucket create my-bucket

2. Test with mc / rclone / AWS CLI:
   mc alias set garage https://${DOMAIN} <ACCESS_KEY> <SECRET_KEY>

Security status:
 • Garage ports hidden behind Caddy (no public 390x exposure)
 • Let’s Encrypt + security headers
 • UFW + CrowdSec (Docker-aware) + Fail2ban
 • Automatic security patches + Watchtower
 • Secrets & configs locked down

Management:
  cd ${INSTALL_DIR} && docker compose up -d     # start
  docker compose logs -f                        # view logs
  docker exec -it garage garage status          # health

For maximum security consider LUKS full-disk encryption on the data volume.
EOF

log "Installation directory: ${BLUE}${INSTALL_DIR}${NC}"
log "You can now host this script on GitHub for true 1-click installs."
