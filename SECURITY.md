# Security

Steady holds mental-health information, so security reports are taken seriously and handled
privately.

## Reporting a problem

**Please don't open a public issue, discussion or pull request about a vulnerability.** Instead:

- use **Report a vulnerability** on this repository's **Security** tab (GitHub's private
  reporting), or
- email **info@openworks.co.za** with "Steady security" in the subject.

Helpful to include: what you found, the version or commit, the steps to reproduce it, and what
someone could do with it. A short report is fine; we'll ask if we need more.

We'll acknowledge your report within three working days, keep you updated while we fix it, and
credit you when the fix is released (unless you'd rather not be named).

## Testing

- **Test on your own copy.** `deploy/test/start.sh` runs the whole stack on your computer with
  fictional patients (see [docs/TESTING.md](docs/TESTING.md)); `deploy/test/security.py` and
  `deploy/test/pentest.py` are the checks we run on every change.
- **Never test against a practice's live server** or try to reach real patients' data. Those
  servers hold health information protected by POPIA, and the patients haven't agreed to be part
  of anyone's test.

## Supported versions

Fixes go into the latest release. Practices' servers install only releases signed by OpenWorks IT
(see [docs/DEPLOY.md](docs/DEPLOY.md), "Signed releases"), and are offered each new one in the app.

## Scope

The server (`server/`), the push relay (`pusher/`), the app (`app/`) and the deployment scripts
(`deploy/`). Problems in PocketBase, Flutter, Caddy or other upstream projects are best reported to
them as well; tell us too if Steady is affected.
