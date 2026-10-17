#!/bin/bash
# Runs once as root on first boot (cloud-init).
# t3.micro has 1GB RAM: dnf can get OOM-killed during early boot, so retry.
for i in 1 2 3; do
  dnf install -y docker && break
  echo "docker install attempt $i failed, retrying in 30s"; sleep 30
done
systemctl enable --now docker
