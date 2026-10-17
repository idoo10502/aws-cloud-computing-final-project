#!/usr/bin/env bash
# Installs Docker (with buildx) on a Linux VM/EC2 instance using Docker's
# official convenience script, then adds a user to the docker group so
# sudo isn't needed before every docker command.
#
# Usage:
#   ./setup_docker-linux.sh            # uses the current user ($USER)
#   ./setup_docker-linux.sh someuser   # or pass a specific username
set -euo pipefail

TARGET_USER="${1:-$USER}"

echo "==> Installing Docker for user: $TARGET_USER"
curl -fsSL https://get.docker.com | sudo sh

echo "==> Adding $TARGET_USER to the docker group"
sudo usermod -aG docker "$TARGET_USER"

echo "==> Enabling Docker to start on boot"
sudo systemctl enable --now docker

echo ""
echo "================================================================"
echo " Docker installed. Log out and back in (or run: newgrp docker)"
echo " for the group membership to take effect without needing sudo."
echo " Verify with: docker --version"
echo "================================================================"
echo ""
echo " If you're on ARM64 (check: uname -m) and need to build linux/amd64"
echo " images (e.g. to run on a standard t3.* EC2 instance), you'll need"
echo " a buildx builder with QEMU emulation:"
echo ""
echo "   docker run --privileged --rm tonistiigi/binfmt --install all"
echo "   docker buildx create --name amd64-builder --driver docker-container --driver-opt network=host --use"
echo ""
echo " Known issue, seen live: without --driver-opt network=host, the build"
echo " container can get a DNS server that can't resolve external hosts"
echo " (e.g. 'no such host' errors pulling docker.io/library/python), even"
echo " though the VM itself resolves DNS fine. The docker-container driver"
echo " runs builds in an isolated network namespace with its own DNS config"
echo " by default — network=host makes it share the host's (working) network"
echo " stack instead."
