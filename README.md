# bigbluebutton-installer
Big Blue Button Installer

Copy `sample.env` to `.env` and update the values for your environment.
`RESERVED_IP` should be set to your DigitalOcean reserved IP so the droplet
is assigned that address after creation.

To enable LDAP logins for Greenlight, populate the LDAP variables in `.env`.
If `LDAP_SERVER` is set, the installer will configure BigBlueButton to use
LDAP authentication.
