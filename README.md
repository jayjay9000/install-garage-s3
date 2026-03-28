# Garage S3 Installer

**One-command production-ready self-hosted S3** — powered by Garage v2.2, Caddy (Let’s Encrypt), Watchtower, CrowdSec, and UFW.

Optimized experience for a single Ubuntu/Debian node.

## ✨ Features
- Fully isolated Garage (no public exposure of S3/RPC ports)
- Automatic HTTPS + security headers
- Auto-updates via Watchtower
- CrowdSec + Fail2ban + automatic security patches
- Interactive prompts with safety checks
- Idempotent & re-runnable

## 📋 Prerequisites
- Fresh Ubuntu 22.04 / 24.04 or Debian 12
- Root or sudo access
- A domain name pointed to your server’s public IP (A + wildcard A record)
- At least 50 GB free disk space

## 🚀 One-Command Install
```bash
curl -fsSL https://raw.githubusercontent.com/jayjay9000/install-garage-s3/main/install-garage.sh | sudo bash
