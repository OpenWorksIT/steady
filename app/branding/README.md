# Practice branding

The practice's logo, used with its permission. It is the practice's own mark and is not covered by Steady's AGPL licence.

- `../assets/brand/mark.png`: the logo mark shown in the app (transparent background).
- `android/`: launcher icons, copied into `android/app/src/main/res/` by `scripts/patch_android.py`.
- `web/`: favicon and home-screen icons, copied into `web/` by `scripts/patch_web.py`.

The tagline and accent colour are in `lib/ui/brand.dart`; the practice name comes from the server (`STEADY_PRACTICE_NAME`).

To brand Steady for another practice, replace these files and the values in `brand.dart`.
