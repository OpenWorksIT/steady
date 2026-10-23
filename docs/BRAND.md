# Steady's identity, and each practice's branding

Steady has one look of its own, and every practice that runs it gets its own name and logo on
top. The two never mix: Steady's identity is in this repository; a practice's branding lives
only on that practice's server.

## Steady

| | |
|---|---|
| Mark | A breathing circle with a wave that settles into a horizon, under a low ember sun: the calm start every patient sees when they open the app |
| Wordmark | "steady", lower case, Figtree Bold (SIL Open Font Licence), letters converted to outlines |
| Colours | Tide `#1E4A5A` (text, wordmark) · Teal `#2F7F86` (mark, icons) · Sage `#CFE3DA` · Sand `#F4EEE4` (backgrounds) · Ember `#D9894A` (the sun; accents, sparingly) |
| Files | `docs/brand/`: `steady-mark.svg`, `steady-logo.svg`, `steady-logo-reverse.svg` (on dark), `steady-icon.svg` (app icon), `steady-icon-foreground.svg` (Android adaptive icon), `identity-sheet.png` |

Steady's mark is shown in the app until a practice's logo has loaded, on servers with no
practice branding, and as the app's icon on phones and in the stores. Use "Steady" with the ™
symbol until the trade mark is registered; never ®.

## A practice's branding

Each server has a `deploy/brand/` folder, outside the code (git ignores it, and `update.sh`
never touches it), holding:

- `brand.json`: `{"name": "...", "tagline": "...", "accent": "#B0690C"}`. Name required;
  tagline (up to 80 characters) and accent colour optional.
- `logo.png`: the practice's logo, PNG, at most 1 MB.

OpenWorks IT installs it; psychologists can't change it in the app. It takes effect at once,
with no restart: the apps pick it up the next time they open.

```sh
# on your own computer: check a brand folder, copy it to the server and install it
deploy/brand.sh push vps1 ~/brands/vr-psych

# or on the server itself
sudo ./brand.sh install /tmp/vr-psych            # a folder, or a .tgz of the two files
./brand.sh show
sudo ./brand.sh remove                           # back to plain Steady
```

Keep each practice's brand folder in OpenWorks IT's own records (not in this repository).

What the practice's branding changes: the logo, name and tagline on the sign-in and welcome
screens, the logo in the app bars and behind the calm start, the accent colour of the
tagline, the invite page, the two-step sign-in label in authenticator apps, and the header of
PDF reports. What it doesn't change: the app's name and icon on the phone and in the stores
(always Steady), and the app's colours.

Servers set up before this used `STEADY_PRACTICE_NAME` in `deploy/.env`; it still names the
practice when no brand is installed.
