#!/bin/bash

DRY_RUN=false
VERBOSE=false
HEALTH_CHECK_ONLY=false

run_cmd() {
  if [ "$VERBOSE" = true ]; then
    eval "$@"
  else
    eval "$@" >/dev/null 2>&1
  fi
}

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--health-check-only] [-v] [-h]

  --dry-run  Skip apt and docker commands.
  --health-check-only  Run HTTPS health checks only (skip droplet creation/install).
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
    --health-check-only)
      HEALTH_CHECK_ONLY=true
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

run_health_check() {
  if [ "$DRY_RUN" = true ] && [ "$HEALTH_CHECK_ONLY" != true ]; then
    echo "✅ BigBlueButton (Docker) dry-run completed. Skipped runtime health checks."
    return 0
  fi

  echo "⏳ Waiting for https://$FULL_DOMAIN on port 443 to become reachable..."
  HEALTH_OK=false
  for i in {1..60}; do
    STATUS_CODE=$(curl -k -sS -o /dev/null -w "%{http_code}" \
      --resolve "$FULL_DOMAIN:443:$RESERVED_IP" "https://$FULL_DOMAIN/" || true)

    if [[ "$STATUS_CODE" =~ ^(200|301|302|303|307|308)$ ]]; then
      HEALTH_OK=true
      break
    fi

    if [ "$VERBOSE" = true ]; then
      echo "Health check attempt $i/60 returned HTTP ${STATUS_CODE:-000}"
    fi
    sleep 10
  done

  if [ "$HEALTH_OK" = true ]; then
    echo "✅ BigBlueButton (Docker) installation completed and https://$FULL_DOMAIN is serving on port 443"
  else
    echo "❌ Health check failed: https://$FULL_DOMAIN did not become ready on port 443"
    echo "Collecting diagnostics from droplet..."

    ssh -o StrictHostKeyChecking=no root@$RESERVED_IP <<EOF4
      cd /opt/bbb-docker || exit 0
      echo "=== docker compose ps ==="
      docker compose ps || true
      echo "=== haproxy logs (last 120 lines) ==="
      docker compose logs --tail=120 haproxy || true
      echo "=== nginx logs (last 120 lines) ==="
      docker compose logs --tail=120 nginx || true
EOF4

    return 1
  fi
}

if [ "$HEALTH_CHECK_ONLY" = true ]; then
  run_health_check
  exit $?
fi

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
echo "4) Custom slug"

echo "Note: You can discover available droplet sizes by running:"
echo "  doctl compute size list -o json | jq -r '.[] | select(.regions | index(\"$REGION\")) | .slug'"

read -rp "Enter choice (1-4): " SIZE_CHOICE

case "$SIZE_CHOICE" in
  1) SIZE="c2-32vcpu-64gb" ;;
  2) SIZE="c2-16vcpu-32gb" ;;
  3) SIZE="c2-8vcpu-16gb" ;;
  4)
    read -rp "Enter custom slug: " SIZE
    ;;
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
DROPLET_IP=$(doctl compute droplet list --format PublicIPv4,Name --no-header | awk -v name="$DROPLET_NAME" '$2==name {print $1}')
echo "📡 Droplet assigned reserved IP: $RESERVED_IP"
echo "🌐 Droplet IP: $DROPLET_IP"

# Remove any old host key for the reserved IP from known_hosts
ssh-keygen -R "$RESERVED_IP" >/dev/null 2>&1 || true

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

OLD_BOOT_ID=$(ssh -o StrictHostKeyChecking=no root@$RESERVED_IP \
  'cat /proc/sys/kernel/random/boot_id')

ssh -o StrictHostKeyChecking=no root@$RESERVED_IP <<EOF2
  VERBOSE=$VERBOSE
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_locks() {
    local timeout_seconds=300
    local waited=0
    while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock >/dev/null 2>&1; do
      if [ "\$waited" -ge "\$timeout_seconds" ]; then
        echo "Timed out waiting for apt/dpkg locks" >&2
        return 1
      fi
      if [ "\$VERBOSE" = true ]; then
        echo "Waiting for apt/dpkg lock holders to finish..."
      fi
      sleep 5
      waited=\$((waited + 5))
    done
  }

  apt_retry() {
    local attempts=0
    local max_attempts=5
    until "\$@"; do
      attempts=\$((attempts + 1))
      if [ "\$attempts" -ge "\$max_attempts" ]; then
        return 1
      fi
      if [ "\$VERBOSE" = true ]; then
        echo "apt command failed, retrying in 10 seconds (attempt \$((attempts + 1))/\$max_attempts)..."
      fi
      sleep 10
      wait_for_apt_locks || return 1
    done
  }

  if [ "$DRY_RUN" != true ]; then
    if command -v cloud-init >/dev/null 2>&1; then
      if [ "\$VERBOSE" = true ]; then
        echo "Waiting for cloud-init to finish..."
      fi
      cloud-init status --wait || true
    fi

    wait_for_apt_locks

    if [ "\$VERBOSE" = true ]; then
      apt_retry apt-get -o DPkg::Lock::Timeout=300 update
      apt_retry apt-get -o DPkg::Lock::Timeout=300 upgrade -y
      apt_retry apt-get -o DPkg::Lock::Timeout=300 install -y git curl gnupg ca-certificates apt-transport-https software-properties-common

      # Install Docker
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo \
        "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt_retry apt-get -o DPkg::Lock::Timeout=300 update
      apt_retry apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt_retry apt-get -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1
      apt_retry apt-get -o DPkg::Lock::Timeout=300 upgrade -y >/dev/null 2>&1
      apt_retry apt-get -o DPkg::Lock::Timeout=300 install -y git curl gnupg ca-certificates apt-transport-https software-properties-common >/dev/null 2>&1

      # Install Docker
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >/dev/null 2>&1
      echo \
        "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt_retry apt-get -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1
      apt_retry apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    fi
  else
    echo "[Dry run] Skipping apt and docker installation commands"
  fi
  reboot
EOF2

echo "⏳ Creating random value for secrets..."

  # Create random value for PostgreSQL secret (others handled on droplet)
  RANDOM_5=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)


# Then wait for reboot
echo "⏳ Waiting for droplet to reboot..."
for i in {1..60}; do
  NEW_BOOT_ID=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 \
    root@$RESERVED_IP 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
  if [[ -n "$NEW_BOOT_ID" && "$NEW_BOOT_ID" != "$OLD_BOOT_ID" ]]; then
    echo "🔄 Detected droplet reboot."
    break
  fi
  if [ "\$VERBOSE" = true ]; then
    echo "Droplet reboot not detected..."
  fi
  sleep 2
done

# Optionally wait for SSH too
until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$RESERVED_IP 'echo "SSH ready"' 2>/dev/null; do
  sleep 2
done


# Set Device name if Block storage is defined
  if [ -n "$BLOCK_STORAGE_NAME" ]; then
    DEVICE="/dev/disk/by-id/scsi-0DO_Volume_${BLOCK_STORAGE_NAME}"
  fi

# Log back in and install BBB

ssh -o StrictHostKeyChecking=no root@$RESERVED_IP <<EOF3
  VERBOSE=$VERBOSE
  POSTGRES_SECRET=""
  echo "Cloning BigBlueButton Docker repository"
  # Clone BBB Docker repo
  if [ "\$VERBOSE" = true ]; then
    git clone --recurse-submodules https://github.com/bigbluebutton/docker.git /opt/bbb-docker
  else
    git clone --recurse-submodules https://github.com/bigbluebutton/docker.git /opt/bbb-docker >/dev/null 2>&1
  fi
  cd /opt/bbb-docker
  echo "block_storage_name = $BLOCK_STORAGE_NAME"
  # Mount attached block storage volume when specified
  if [ -n "$BLOCK_STORAGE_NAME" ]; then
    echo "Mounting block storage inside droplet"
    mkdir -p /opt/bbb-docker/data
    # Wait for the block device to become available
    echo "⏳ Waiting for block device to become available..."
    for i in {1..30}; do
      [ -e "${DEVICE}" ] && break
      if [ "\$VERBOSE" = true ]; then
        echo "Device $DEVICE still not detected"
      fi
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

    # Persist SSH host keys on the volume
    mkdir -p /opt/bbb-docker/data/ssh_host_keys
    if [ -f /opt/bbb-docker/data/ssh_host_keys/ssh_host_rsa_key ]; then
      cp /opt/bbb-docker/data/ssh_host_keys/ssh_host_* /etc/ssh/
      systemctl restart ssh >/dev/null 2>&1
    else
      cp /etc/ssh/ssh_host_* /opt/bbb-docker/data/ssh_host_keys/
    fi

    # Reuse persisted Postgres secret when available
    if [ -f /opt/bbb-docker/data/postgres_secret ]; then
      POSTGRES_SECRET=$(cat /opt/bbb-docker/data/postgres_secret)
    else
      POSTGRES_SECRET=""
    fi
  fi

  # Ensure data directory exists for storing secrets
  mkdir -p /opt/bbb-docker/data

  # Load or generate persistent secrets
  if [ -f /opt/bbb-docker/data/secret_SHARED_SECRET ]; then
    SHARED_SECRET=\$(cat /opt/bbb-docker/data/secret_SHARED_SECRET)
  else
    SHARED_SECRET=\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
    echo "\$SHARED_SECRET" > /opt/bbb-docker/data/secret_SHARED_SECRET
  fi
  if [ -f /opt/bbb-docker/data/secret_ETHERPAD_API_KEY ]; then
    ETHERPAD_API_KEY=\$(cat /opt/bbb-docker/data/secret_ETHERPAD_API_KEY)
  else
    ETHERPAD_API_KEY=\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
    echo "\$ETHERPAD_API_KEY" > /opt/bbb-docker/data/secret_ETHERPAD_API_KEY
  fi
  if [ -f /opt/bbb-docker/data/secret_RAILS_SECRET ]; then
    RAILS_SECRET=\$(cat /opt/bbb-docker/data/secret_RAILS_SECRET)
  else
    RAILS_SECRET=\$(head /dev/urandom | tr -dc a-f0-9 | head -c 128)
    echo "\$RAILS_SECRET" > /opt/bbb-docker/data/secret_RAILS_SECRET
  fi
  if [ -f /opt/bbb-docker/data/secret_FSESL_PASSWORD ]; then
    FSESL_PASSWORD=\$(cat /opt/bbb-docker/data/secret_FSESL_PASSWORD)
  else
    FSESL_PASSWORD=\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
    echo "\$FSESL_PASSWORD" > /opt/bbb-docker/data/secret_FSESL_PASSWORD
  fi
  if [ -f /opt/bbb-docker/data/secret_TURN_SECRET ]; then
    TURN_SECRET=\$(cat /opt/bbb-docker/data/secret_TURN_SECRET)
  else
    TURN_SECRET=\$(head /dev/urandom | tr -dc A-Za-f0-9 | head -c 32)
    echo "\$TURN_SECRET" > /opt/bbb-docker/data/secret_TURN_SECRET
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
  if [ "$KEYCLOAK_ENABLED" = true ]; then
    sed -i "/^AUTH=/d" .env
    echo "AUTH=oauth2" >> .env
    echo "OAUTH2_PROVIDER=keycloak" >> .env
    echo "OAUTH2_CLIENT_ID=bbb" >> .env
    echo "OAUTH2_CLIENT_SECRET=$KEYCLOAK_BBB_SECRET" >> .env
    echo "OAUTH2_ISSUER=https://$FULL_DOMAIN:8081/realms/master" >> .env
  fi

  # Apply secrets to .env
  sed -i "s/SHARED_SECRET=.*/SHARED_SECRET=\$SHARED_SECRET/" .env
  sed -i "s/ETHERPAD_API_KEY=.*/ETHERPAD_API_KEY=\$ETHERPAD_API_KEY/" .env
  sed -i "s/RAILS_SECRET=.*/RAILS_SECRET=\$RAILS_SECRET/" .env
  sed -i "s/FSESL_PASSWORD=.*/FSESL_PASSWORD=\$FSESL_PASSWORD/" .env

  # Determine persistent Postgres secret
  if [ -z "\$POSTGRES_SECRET" ]; then
    POSTGRES_SECRET=$RANDOM_5
    if [ -n "$BLOCK_STORAGE_NAME" ]; then
      echo "$POSTGRES_SECRET" > /opt/bbb-docker/data/postgres_secret
    fi
  fi
  sed -i "s/POSTGRESQL_SECRET=.*/POSTGRESQL_SECRET=$POSTGRES_SECRET/" .env
  sed -i "s/.*TURN_SECRET=.*/TURN_SECRET=\$TURN_SECRET/" .env

  # Copy template from persistent folder - deprecated for now
  cp data/docker-compose.tmpl.yml .

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
  if [ "$KEYCLOAK_ENABLED" = true ]; then
    docker run -d --name keycloak -p 8081:8080 \
      -e KEYCLOAK_ADMIN="$KEYCLOAK_ADMIN" \
      -e KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
      -e LDAP_URL="$KEYCLOAK_LDAP_URL" \
      -e LDAP_BASE_DN="$KEYCLOAK_LDAP_BASE_DN" \
      -e LDAP_BIND_DN="$KEYCLOAK_LDAP_BIND_DN" \
      -e LDAP_BIND_CREDENTIALS="$KEYCLOAK_LDAP_BIND_PASSWORD" \
      quay.io/keycloak/keycloak:latest start-dev
  fi
EOF3

run_health_check
