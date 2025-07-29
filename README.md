# BigBlueButton Installer
This script installs an instance of BigBlueButton on beefy server architecture sufficient for 
500-1000 concurrent users in a webinar. The background infrastructure is DigitalOcean droplets.

# Usage
Copy `sample.env` to `.env` and update the values for your environment.
`RESERVED_IP` should be set to your DigitalOcean reserved IP so the droplet
is assigned that address after creation.

If you have a DigitalOcean block storage volume, set `BLOCK_STORAGE_NAME` to the
name of that volume and it will be attached and mounted at `/opt/bbb-docker/data`.
The installer waits for the device to become available before formatting and
mounting it.

To enable LDAP logins for Greenlight, populate the LDAP variables in `.env`.
If `LDAP_SERVER` is set, the installer will configure BigBlueButton to use
LDAP authentication.

Run `./create-bbb.sh -h` to see available options. Passing `--dry-run` will skip
all `apt` and `docker` commands so you can verify what the script would do
without performing the installation.

## Persisting SSH Host Keys

Each new droplet generates fresh SSH host keys. To keep a consistent
fingerprint across reinstallations:

1. Create a directory on the attached block storage volume such as
   `/opt/bbb-docker/data/ssh_host_keys`.
2. Before deleting a droplet, copy `/etc/ssh/ssh_host_*` into that directory.
3. When you run the installer again, it restores any saved keys from that
   directory, restarts SSH, and saves newly generated keys when none are found.

This keeps the host key consistent so clients do not see a change on each
install.

## DigitalOcean Snapshot Pricing

DigitalOcean charges **$0.05 USD per GB** of snapshot storage per month. This
rate applies to both droplet and volume snapshots.
