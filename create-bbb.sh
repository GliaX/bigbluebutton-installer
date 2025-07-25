#!/bin/bash

DRY_RUN=false
VERBOSE=false

run_cmd() {
  if [ "$VERBOSE" = true ]; then
    eval "$@"
  else
    eval "$@" >/dev/null 2>&1
  fi
}

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [-v] [-h]

  --dry-run  Skip apt and docker commands.
  -v         Enable verbose output.
  -h         Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# === CONFIG ===
# Load user configuration from .env
if [ -f .env ]; then
  set -a
  source .env
  set +a
else
  echo "Missing .env file. Copy sample.env to .env and update the values." >&2
  exit 1
fi

# Derived values
FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"

# === CHECK FOR EXISTING DROPLET ===
echo "✅ Checking for existing droplet '$DROPLET_NAME'..."
if doctl compute droplet list --format Name --no-header | grep -Fxq "$DROPLET_NAME"; then
  read -r -p "Droplet '$DROPLET_NAME' already exists. Delete it? [y/N] " RESP
  RESP=${RESP:-N}
  if [[ "$RESP" =~ ^[Yy]$ ]]; then
    DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header | awk -v name="$DROPLET_NAME" '$2==name {print $1}')
    if [ -n "$DROPLET_ID" ]; then
      echo "Deleting droplet '$DROPLET_NAME'..."
      run_cmd doctl compute droplet delete "$DROPLET_ID" --force
    fi
  else
    echo "Exiting without creating a new droplet."
    exit 0
  fi
fi

# === PROMPT FOR SIZE ===
echo "Choose droplet size:"
echo "1) 32 vCPU / 64 GB RAM / 800GB SSD  → slug: c2-32vcpu-64gb"
echo "2) 16 vCPU / 32 GB RAM / 400GB SSD  → slug: c2-16vcpu-32gb"
echo "3) 8 vCPU / 16 GB RAM / 200GB SSD  → slug: c2-8vcpu-16gb"

read -rp "Enter choice (1-3): " SIZE_CHOICE

case "$SIZE_CHOICE" in
  1) SIZE="c2-32vcpu-64gb" ;;
  2) SIZE="c2-16vcpu-32gb" ;;
  3) SIZE="c2-8vcpu-16gb" ;;
  *) echo "Invalid choice. Exiting." ; exit 1 ;;
esac

# === GET SSH KEY ===
SSH_KEY_ID=$(doctl compute ssh-key list --format ID --no-header | head -n 1)

# === CREATE DROPLET ===
echo "💧 Creating droplet '$DROPLET_NAME' with size '$SIZE'..."
run_cmd doctl compute droplet create $DROPLET_NAME \
  --region $REGION \
  --image $IMAGE \
  --size $SIZE \
  --ssh-keys $SSH_KEY_ID \
  --wait

# === ASSIGN RESERVED IP ===
DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header | grep "$DROPLET_NAME" | awk '{print $1}')
echo "📡 Assigning reserved IP '$RESERVED_IP' to droplet..."
run_cmd doctl compute reserved-ip-action assign $RESERVED_IP $DROPLET_ID
DROPLET_IP=$RESERVED_IP
echo "📡 Droplet assigned reserved IP: $DROPLET_IP"

# === ATTACH BLOCK STORAGE ===
if [ -n "$BLOCK_STORAGE_NAME" ]; then
  VOLUME_ID=$(doctl compute volume list --region "$REGION" --format ID,Name --no-header | grep "^.*\s$BLOCK_STORAGE_NAME$" | awk '{print $1}')
  if [ -z "$VOLUME_ID" ]; then
    echo "💾 Block storage volume '$BLOCK_STORAGE_NAME' not found in region $REGION" >&2
    exit 1
  fi
  echo "💾 Attaching block storage volume '$BLOCK_STORAGE_NAME'..."
  run_cmd doctl compute volume-action attach "$VOLUME_ID" "$DROPLET_ID"
fi


# === INSTALL BBB DOCKER ===

echo "⏳ Waiting for network to stabilize..."
sleep 5

ssh -o StrictHostKeyChecking=no root@$DROPLET_IP <<EOF2
  VERBOSE=$VERBOSE
  export DEBIAN_FRONTEND=noninteractive
  if [ "$DRY_RUN" != true ]; then
    if [ "\$VERBOSE" = true ]; then
      apt update && apt upgrade -y
      apt install -y git curl gnupg ca-certificates apt-transport-https software-properties-common

      # Install Docker
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo \
        "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt update
      apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      reboot
    else
      apt update >/dev/null 2>&1 && apt upgrade -y >/dev/null 2>&1
      apt install -y git curl gnupg ca-certificates apt-transport-https software-properties-common >/dev/null 2>&1

      # Install Docker
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >/dev/null 2>&1
      echo \
        "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt update >/dev/null 2>&1
      apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
      reboot >/dev/null 2>&1
    fi
  else
    echo "[Dry run] Skipping apt and docker installation commands"
  fi
EOF2

echo "⏳ Creating random values for secrets..."

  # Create random values for secrets
  RANDOM_1=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
  RANDOM_2=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
  RANDOM_3=$(head /dev/urandom | tr -dc a-f0-9 | head -c 128)
  RANDOM_4=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
  RANDOM_5=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
  TURN_SECRET=$(head /dev/urandom | tr -dc A-Za-f0-9 | head -c 32)


# Then wait for reboot
echo "⏳ Waiting for droplet to reboot..."
while ping -c 1 "$DROPLET_IP" &> /dev/null; do sleep 1; done
while ! ping -c 1 "$DROPLET_IP" &> /dev/null; do sleep 1; done

# Optionally wait for SSH too
until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$DROPLET_IP 'echo "SSH ready"' 2>/dev/null; do
  sleep 2
done



# Log back in and install BBB


ssh -o StrictHostKeyChecking=no root@$DROPLET_IP <<EOF3
  VERBOSE=$VERBOSE
  # Clone BBB Docker repo
  if [ "\$VERBOSE" = true ]; then
    git clone https://github.com/bigbluebutton/docker.git /opt/bbb-docker
  else
    git clone https://github.com/bigbluebutton/docker.git /opt/bbb-docker >/dev/null 2>&1
  fi
  cd /opt/bbb-docker

  # Mount attached block storage volume when specified
  if [ -n "$BLOCK_STORAGE_NAME" ]; then
    echo "Mounting block storage inside droplet"
    DEVICE="/dev/disk/by-id/scsi-0DO_Volume_${BLOCK_STORAGE_NAME}"
    mkdir -p /opt/bbb-docker/data
    # Wait for the block device to become available
    echo "⏳ Waiting for block device to become available..."
    for i in {1..30}; do
      [ -e "${DEVICE}" ] && break
      sleep 2
    done
    if ! blkid "${DEVICE}" >/dev/null 2>&1; then
      mkfs.ext4 -F "${DEVICE}" >/dev/null 2>&1
    fi
    if ! grep -q "${DEVICE}" /etc/fstab; then
      echo "${DEVICE} /opt/bbb-docker/data ext4 defaults,nofail 0 0" >> /etc/fstab
      systemctl daemon-reload >/dev/null 2>&1
    fi
    mount /opt/bbb-docker/data >/dev/null 2>&1
  fi

  # Create docker-compose.yml from template
  cp docker-compose.tmpl.yml docker-compose.yml >/dev/null 2>&1
  # Create .env from sample.env
  cp sample.env .env >/dev/null 2>&1

  # Set ENABLE_RECORDING to true
  sed -i '/^ENABLE_RECORDING=/d' .env
  echo "ENABLE_RECORDING=true" >> .env

  # Replace DOMAIN
  sed -i "s|^DOMAIN=.*|DOMAIN=$FULL_DOMAIN|" .env

  # Set LetsEncrypt email
  sed -i "s|^LETSENCRYPT_EMAIL=.*|LETSENCRYPT_EMAIL=$EMAIL|" .env

  # Set external IPv4 (must match droplet IP)
  sed -i "s|^EXTERNAL_IPv4=.*|EXTERNAL_IPv4=$DROPLET_IP|" .env

  sed -i "s|^STUN_IP=.*|STUN_IP=$DROPLET_IP|" .env

  # Configure LDAP authentication when LDAP_SERVER is set
  if [ -n "$LDAP_SERVER" ]; then
    sed -i '/^AUTH=/d' .env
    echo "AUTH=ldap" >> .env
    echo "LDAP_SERVER=$LDAP_SERVER" >> .env
    echo "LDAP_PORT=$LDAP_PORT" >> .env
    echo "LDAP_METHOD=$LDAP_METHOD" >> .env
    echo "LDAP_BASE=$LDAP_BASE" >> .env
    echo "LDAP_UID=$LDAP_UID" >> .env
    echo "LDAP_BIND_DN=$LDAP_BIND_DN" >> .env
    echo "LDAP_PASSWORD=$LDAP_PASSWORD" >> .env
  fi

  # Change secrets to random values
  sed -i "s/SHARED_SECRET=.*/SHARED_SECRET=$RANDOM_1/" .env
  sed -i "s/ETHERPAD_API_KEY=.*/ETHERPAD_API_KEY=$RANDOM_2/" .env
  sed -i "s/RAILS_SECRET=.*/RAILS_SECRET=$RANDOM_3/" .env
  sed -i "s/FSESL_PASSWORD=.*/FSESL_PASSWORD=$RANDOM_4/" .env
  sed -i "s/POSTGRESQL_SECRET=.*/POSTGRESQL_SECRET=$RANDOM_5/" .env
  sed -i "s/.*TURN_SECRET=.*/TURN_SECRET=$TURN_SECRET/" .env

  # Generate docker-compose YAML file
  ./scripts/generate-compose >/dev/null 2>&1

  # Run BBB via Docker Compose
  if [ "$DRY_RUN" != true ]; then
    if [ "\$VERBOSE" = true ]; then
      docker compose up -d
    else
      docker compose up -d >/dev/null 2>&1
    fi
  else
    echo "[Dry run] Skipping 'docker compose up -d'"
  fi
EOF3
echo "✅ BigBlueButton (Docker) installation started on https://$FULL_DOMAIN"
