#!/usr/bin/env bash
# Telly server: creates an Always Free Ampere A1 VM (Ubuntu 24.04) in Oracle Cloud, London.
# Run it in Oracle Cloud Shell:  bash <(curl -sL https://raw.githubusercontent.com/porkikkk/telly-tonight-videos/main/tools/oracle/create_server.sh)
# Safe to run again: it reuses the network and the server if they already exist.
set -euo pipefail
say() { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }

T="${OCI_TENANCY:-}"
[ -n "$T" ] || T=$(oci os ns get-metadata --query 'data."default-s3-compartment-id"' --raw-output)
say "Tenancy: ${T:0:30}..."

# SSH key that lives in Cloud Shell (you never need to download it)
mkdir -p ~/.ssh
[ -f ~/.ssh/telly ] || ssh-keygen -q -t rsa -b 4096 -N "" -f ~/.ssh/telly -C telly-server  # RSA: Cloud Shell runs in FIPS mode (no ed25519)

# --- network: VCN + internet gateway + public subnet (SSH open, like Oracle's default) ---
VCN=$(oci network vcn list -c "$T" --display-name telly-vcn --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -z "$VCN" ] || [ "$VCN" = "null" ]; then
  say "Creating network"
  VCN=$(oci network vcn create -c "$T" --cidr-block 10.0.0.0/16 --display-name telly-vcn --dns-label tellyvcn \
        --wait-for-state AVAILABLE --query data.id --raw-output)
  IGW=$(oci network internet-gateway create -c "$T" --vcn-id "$VCN" --is-enabled true --display-name telly-igw \
        --wait-for-state AVAILABLE --query data.id --raw-output)
  RT=$(oci network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output)
  oci network route-table update --rt-id "$RT" --force \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null
fi
SUB=$(oci network subnet list -c "$T" --vcn-id "$VCN" --display-name telly-subnet --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -z "$SUB" ] || [ "$SUB" = "null" ]; then
  SUB=$(oci network subnet create -c "$T" --vcn-id "$VCN" --cidr-block 10.0.0.0/24 --display-name telly-subnet \
        --dns-label sub --wait-for-state AVAILABLE --query data.id --raw-output)
fi
say "Network ready"

# --- server ---
ID=$(oci compute instance list -c "$T" --display-name telly-server --lifecycle-state RUNNING --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -z "$ID" ] || [ "$ID" = "null" ]; then
  IMG=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
        --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --all \
        | jq -r '[.data[] | select(."display-name" | test("Minimal") | not)][0].id')
  ADS=$(oci iam availability-domain list -c "$T" --query 'data[].name' --raw-output | jq -r '.[]')
  for size in "4 24" "2 12" "1 6"; do
    set -- $size
    for AD in $ADS; do
      say "Trying ${1} OCPU / ${2} GB in $AD"
      if ID=$(oci compute instance launch -c "$T" --availability-domain "$AD" --display-name telly-server \
              --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$1,\"memoryInGBs\":$2}" \
              --image-id "$IMG" --subnet-id "$SUB" --assign-public-ip true --boot-volume-size-in-gbs 100 \
              --ssh-authorized-keys-file ~/.ssh/telly.pub \
              --wait-for-state RUNNING --max-wait-seconds 900 --query data.id --raw-output 2>/tmp/telly_err); then
        break 2
      fi
      ID=""
      if grep -qiE "capacity|LimitExceeded" /tmp/telly_err; then echo "   no free capacity there"; continue; fi
      cat /tmp/telly_err; exit 1
    done
  done
  if [ -z "$ID" ]; then
    echo; echo "Oracle has no free Ampere capacity in London right now. Run this script again later (it often frees up within hours)."
    exit 2
  fi
fi

IP=$(oci compute instance list-vnics --instance-id "$ID" --query 'data[0]."public-ip"' --raw-output)
cat > ~/.ssh/config <<EOF
Host telly
  HostName $IP
  User ubuntu
  IdentityFile ~/.ssh/telly
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
EOF
chmod 600 ~/.ssh/config
say "Server is running: $IP"
echo "Waiting for SSH..."
for i in $(seq 1 40); do ssh -o ConnectTimeout=5 telly true 2>/dev/null && break; sleep 6; done
ssh telly 'echo "SSH OK: $(hostname), $(nproc) CPUs, $(free -g | awk "/Mem/{print \$2}") GB RAM"'
echo "TELLY_SERVER_READY $IP"
