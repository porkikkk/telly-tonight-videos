#!/usr/bin/env bash
# Telly server setup (runs ON the Oracle VM, Ubuntu 24.04 arm64): tools for TikTok posting and video editing,
# then registers the VM as a GitHub Actions runner for porkikkk/telly-tonight-kit (labels: self-hosted, oracle, uk).
# From Cloud Shell:  ssh -t telly 'bash <(curl -sL https://raw.githubusercontent.com/porkikkk/telly-tonight-videos/main/tools/oracle/setup_server.sh)'
set -euo pipefail
say() { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# A fresh Ubuntu VM runs its own automatic updates first and holds the apt lock for a few minutes.
sudo systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
wait_apt() {
  while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "   waiting for Ubuntu's own updates to finish..."; sleep 10
  done
}
APT="sudo -E apt-get -o DPkg::Lock::Timeout=900"

say "System packages"
wait_apt
$APT update -q
$APT install -y -q git curl jq unzip ffmpeg python3-pip python3-venv xvfb \
     fonts-dejavu fonts-noto-color-emoji fonts-liberation

if ! sudo swapon --show | grep -q /swapfile; then
  say "4 GB swap"
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

say "Playwright + Chromium (TikTok Studio)"
sudo pip3 install -q --break-system-packages playwright==1.55.0
wait_apt
sudo python3 -m playwright install-deps chromium
python3 -m playwright install chromium

RUNNER=~/actions-runner
if [ ! -f "$RUNNER/.runner" ]; then
  say "GitHub Actions runner"
  mkdir -p "$RUNNER" && cd "$RUNNER"
  V=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
  curl -sL -o r.tgz "https://github.com/actions/runner/releases/download/v$V/actions-runner-linux-arm64-$V.tar.gz"
  tar xzf r.tgz && rm r.tgz
  wait_apt
  sudo ./bin/installdependencies.sh >/dev/null
  echo
  echo "Paste the token from GitHub (telly-tonight-kit → Settings → Actions → Runners → New self-hosted runner,"
  echo "the long code after --token) and press Enter:"
  read -r TOKEN
  ./config.sh --url https://github.com/porkikkk/telly-tonight-kit --token "$TOKEN" \
      --name telly-server --labels oracle,uk --work _work --unattended --replace
  sudo ./svc.sh install "$USER"
  sudo ./svc.sh start
fi

say "Check"
python3 -c "import playwright; print('playwright OK')"
ffmpeg -version | head -1
sudo "$RUNNER/svc.sh" status | grep -E "active|Active" | head -2
echo "TELLY_SETUP_DONE"
