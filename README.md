# BigBlueButton Installer
This script installs an instance of BigBlueButton on beefy server architecture sufficient for 
500-1000 concurrent users in a webinar. The background infrastructure is DigitalOcean droplets.

# Usage
Copy `sample.env` to `.env` and update the values for your environment.
`RESERVED_IP` should be set to your DigitalOcean reserved IP so the droplet
is assigned that address after creation.

If you have a DigitalOcean block storage volume, set `BLOCK_STORAGE_NAME` to the
name of that volume and it will be attached and mounted at `/opt/bbb-docker/data`.

To enable LDAP logins for Greenlight, populate the LDAP variables in `.env`.
If `LDAP_SERVER` is set, the installer will configure BigBlueButton to use
LDAP authentication.

Run `./create-bbb.sh -h` to see available options. Passing `--dry-run` will skip
all `apt` and `docker` commands so you can verify what the script would do
without performing the installation.
