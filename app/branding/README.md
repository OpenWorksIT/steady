# Steady's icons

Steady's own launcher and web icons. Every practice's app uses these: one app in the stores,
named Steady, which takes on the practice's logo, name and tagline once it is linked to the
practice's server. The practice's branding never lives in this repository; see
[docs/BRAND.md](../../docs/BRAND.md).

- `../assets/brand/steady-mark.png`: Steady's mark, shown in the app until a practice logo loads.
- `android/`: launcher icons (adaptive on Android 8 and later), copied into
  `android/app/src/main/res/` by `scripts/patch_android.py`.
- `web/`: favicon and home-screen icons, copied into `web/` by `scripts/patch_web.py`.

The sources are the SVGs in `docs/brand/`.
