#!/bin/bash

# === CONFIG ===
DOMAIN="glia.org"
SUBDOMAIN="webinar"
FULL_DOMAIN="$SUBDOMAIN.$DOMAIN"
EMAIL="your@email.com"
GANDI_API_KEY="INSERT_KEY_HERE"  # Replace with your actual key
REGION="tor1"
IMAGE="ubuntu-24-04-x64"
DROPLET_NAME="bbb-docker-webinar"
RESERVED_IP="0.0.0.0"  # Replace with your reserved IP

# === PROMPT FOR SIZE ===
echo "Choose droplet size:"
echo "1) 32 vCPU / 64 GB RAM / 800GB SSD  → slug: c2-32vcpu-64gb"
echo "2) 16 vCPU / 32 GB RAM / 400GB SSD  → slug: c2-16vcpu-32gb"
echo "3) 8 vCPU / 16 GB RAM / 400GB SSD  → slug: c2-8vcpu-16gb"

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
echo "Creating droplet '$DROPLET_NAME' with size '$SIZE'..."
doctl compute droplet create $DROPLET_NAME \
  --region $REGION \
  --image $IMAGE \
  --size $SIZE \
  --ssh-keys $SSH_KEY_ID \
  --wait

# === ASSIGN RESERVED IP ===
DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header | grep "$DROPLET_NAME" | awk '{print $1}')
echo "Assigning reserved IP '$RESERVED_IP' to droplet..."
doctl compute reserved-ip-action assign $RESERVED_IP $DROPLET_ID
DROPLET_IP=$RESERVED_IP
echo "Droplet assigned reserved IP: $DROPLET_IP"

# === UPDATE GANDI DNS ===
echo "Updating DNS A record for $FULL_DOMAIN → $DROPLET_IP..."
curl -s -X PUT "https://api.gandi.net/v5/livedns/domains/$DOMAIN/records/$SUBDOMAIN/A" \
  -H "Authorization: Bearer $GANDI_API_KEY" \
  -H "Content-Type: application/json" \
  --data "{\"rrset_values\": [\"$DROPLET_IP\"], \"rrset_ttl\": 300}"

echo "Waiting 60 seconds for DNS to propagate..."
sleep 60

# === INSTALL BBB DOCKER ===
ssh -o StrictHostKeyChecking=no root@$DROPLET_IP <<EOF
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt upgrade -y
  apt install -y git curl gnupg ca-certificates apt-transport-https software-properties-common

  # Install Docker
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \\
    \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  reboot
EOF

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

ssh -o StrictHostKeyChecking=no root@$DROPLET_IP <<EOF
  # Clone BBB Docker repo
  git clone https://github.com/bigbluebutton/docker.git /opt/bbb-docker
  cd /opt/bbb-docker


  # Create docker-compose.yml from template
  cp docker-compose.tmpl.yml docker-compose.yml
  # Create .env from sample.env
  cp sample.env .env

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

  # Change secrets to random values

  sed -i "s/SHARED_SECRET=.*/SHARED_SECRET=$RANDOM_1/" .env
  sed -i "s/ETHERPAD_API_KEY=.*/ETHERPAD_API_KEY=$RANDOM_2/" .env
  sed -i "s/RAILS_SECRET=.*/RAILS_SECRET=$RANDOM_3/" .env
  sed -i "s/FSESL_PASSWORD=.*/FSESL_PASSWORD=$RANDOM_4/" .env
  sed -i "s/POSTGRESQL_SECRET=.*/POSTGRESQL_SECRET=$RANDOM_5/" .env
  sed -i "s/.*TURN_SECRET=.*/TURN_SECRET=$TURN_SECRET/" .env

  # Generate docker-compose YAML file
  ./scripts/generate-compose

  # Run BBB via Docker Compose
  docker compose up -d
EOF

echo "✅ BigBlueButton (Docker) installation started on https://$FULL_DOMAIN"
