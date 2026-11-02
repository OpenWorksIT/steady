# OpenWorks' own server (vps3)

A server of its own for the two things that are OpenWorks IT's rather than a practice's:

- the **fleet view** at fleet.steadyapp.co.za ([FLEET.md](FLEET.md))
- the **community forum** at community.steadyapp.co.za ([COMMUNITY.md](COMMUNITY.md))

Nothing else runs on it: no Steady practice server, no Shap. A Caddy (`ops/compose.yml`) owns
ports 80/443, gets the certificates, and passes each site on over a Docker network of that
site's own: `fleet-edge` and `community-edge`. Only Caddy is on both, so the forum (a big
application with plugins) can't reach the fleet view, which holds every practice server's fleet
key, and the fleet view can't reach the forum's insides. Each site's Caddy file lives next to its
code (`fleet/fleet.caddy`, `community/community.caddy`), so a `git pull` updates them.

```
internet ──443──> caddy ──fleet-edge─────> fleet:8080     (fleet/compose.yml)
                        └─community-edge─> community:80   (Discourse, /var/discourse)
```

## The server

**2 vCPU, 4 GB RAM, 60 GB disk, Debian 13, in South Africa** (Rackzar, like vps1 and vps2).
Discourse is the heavy one: about 1 GB running and more while it rebuilds. The fleet view needs
a few MB. The disk is mostly the forum's uploads and its seven daily backups.

Ask Rackzar in the order whether the disk is encrypted at rest (the same question as for vps2).

## 1. DNS

A records pointing at vps3's address:

- `fleet.steadyapp.co.za` (move it from vps1 if it's there already)
- `community.steadyapp.co.za`

## 2. Harden it first

As root on the new server, before anything else:

```bash
apt update && apt full-upgrade -y
apt install -y git curl ufw unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# your SSH key in, then passwords off (a file that sorts first, so the provider's can't win)
mkdir -p ~/.ssh && nano ~/.ssh/authorized_keys     # paste your public key
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/00-a-openworks.conf
sshd -t && systemctl reload ssh
```

From your own computer, check a key login works and a password one doesn't, **before** you close
the root session:

```bash
ssh -o PasswordAuthentication=no -o PubkeyAuthentication=no root@<vps3> true   # must be refused
ssh root@<vps3> true                                                          # must work
```

Then the firewall, swap and Docker:

```bash
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw enable
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
curl -fsSL https://get.docker.com | sh
```

## 3. The repository and Caddy

The repository is public, so no deploy key is needed:

```bash
git clone https://github.com/OpenWorksIT/steady.git /opt/steady
cd /opt/steady && docker compose -f ops/compose.yml up -d
```

Caddy starts and creates the `fleet-edge` and `community-edge` networks. It asks Let's Encrypt
for both certificates once DNS points here; until the fleet view and the forum are up, their
addresses answer 502.

## 4. The fleet view

[FLEET.md](FLEET.md), "Setting up the fleet view", steps 2 onwards.

## 5. The forum

[COMMUNITY.md](COMMUNITY.md), from "1. Before you start".

## Updating

The fleet view holds every practice server's fleet key, so vps3 runs only code OpenWorks has
signed, like the practice servers: the newest release tag, checked against the signing key
(the same one-line `allowed_signers` file as on the practice servers, DEPLOY.md "Signed
releases"; put it in `/opt/steady/deploy/secrets/` here too). A plain `git pull` would run
whatever is on GitHub's main branch, signed or not. (Until a signed release includes `ops/`,
from 1.0.4, the server stays on the main branch it was cloned from.)

```bash
cd /opt/steady && git fetch -q --tags origin
t="$(git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
git cat-file tag "$t" | grep -qx "tag $t" \
  && git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=deploy/secrets/allowed_signers verify-tag "$t" \
  && git checkout -q --detach "$t" && echo "now on $t"
docker compose -f fleet/compose.yml up -d --build                  # the fleet view
docker compose -f ops/compose.yml exec caddy caddy reload --config /etc/caddy/ops/Caddyfile
docker compose -f ops/compose.yml pull && docker compose -f ops/compose.yml up -d   # Caddy itself, now and then
```

The forum updates separately (COMMUNITY.md, "Updates"). Debian patches itself.

## Backups

- **Fleet view:** `/var/lib/steady-fleet` (users, servers and their keys, audit log). Small;
  copy it off encrypted with the forum's backups (COMMUNITY.md, "Backups"):
  `tar -C /var/lib -c steady-fleet | age -R /root/backup.age.pub > /srv/offsite/fleet-$(date +%F).tar.age`
- **Forum:** Discourse's own daily backups, copied off as in COMMUNITY.md.

## Optional: the fleet view only from known addresses

The fleet view already needs a password and an authenticator code. To also hide it from
everyone else, allow only your addresses (an office IP, or your WireGuard address) by adding
this inside the site block in `fleet/fleet.caddy`, then reloading Caddy:

```
@outside not remote_ip 198.51.100.7 2001:db8::/64
respond @outside 404
```

Only worth it if those addresses don't change.
