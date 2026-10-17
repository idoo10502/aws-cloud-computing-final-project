#!/usr/bin/env bash
# Lesson 1 setup script (Ubuntu): installs Terraform (Part A) + AWS CLI (Part B).
# Usage:
#   ./setup.sh            install Terraform + AWS CLI
#   ./setup.sh --purge    remove Terraform + AWS CLI installed by this script

set -euo pipefail

HASHICORP_KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
HASHICORP_LIST="/etc/apt/sources.list.d/hashicorp.list"
AWS_INSTALL_DIR="/usr/local/aws-cli"
AWS_BIN_DIR="/usr/local/bin"

log() { echo -e "\n==> $*"; }

# ---------- Part A: Terraform ----------

install_terraform() {
  log "Installing Terraform..."
  sudo apt-get update -y
  sudo apt-get install -y gnupg software-properties-common curl wget

  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o "$HASHICORP_KEYRING"
  echo "deb [signed-by=$HASHICORP_KEYRING] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee "$HASHICORP_LIST" > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y terraform

  terraform -version
}

purge_terraform() {
  log "Purging Terraform..."
  sudo apt-get remove --purge -y terraform || true
  sudo rm -f "$HASHICORP_KEYRING" "$HASHICORP_LIST"
  sudo apt-get update -y
}

# ---------- Part B: AWS CLI ----------

install_aws_cli() {
  log "Installing AWS CLI..."
  sudo apt-get install -y unzip curl

  local arch pkg_url
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  pkg_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64) pkg_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl -sSL "$pkg_url" -o "$tmp_dir/awscliv2.zip"
  unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir"
  sudo "$tmp_dir/aws/install" --update
  rm -rf "$tmp_dir"

  aws --version
}

purge_aws_cli() {
  log "Purging AWS CLI..."
  sudo rm -rf "$AWS_INSTALL_DIR"
  sudo rm -f "$AWS_BIN_DIR/aws" "$AWS_BIN_DIR/aws_completer"
}

purge_aws_config() {
  log "Purging AWS config directory (~/.aws)..."
  rm -rf "$HOME/.aws"
}

purge_terraform_local() {
  log "Purging Terraform local cache (~/.terraform.d)..."
  rm -rf "$HOME/.terraform.d"
}

# ---------- Main ----------

if [[ "${1:-}" == "--purge" ]]; then
  purge_terraform
  purge_terraform_local
  purge_aws_cli
  purge_aws_config
  log "Done. Terraform and AWS CLI are fully removed, as if never installed."
else
  install_terraform
  install_aws_cli
  log "Done. Run 'aws configure' next to set up your AWS credentials."
fi
