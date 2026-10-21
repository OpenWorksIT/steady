# Steady in Sorted

[Sorted](https://github.com/OpenWorksIT/sorted) (the practice software) shows a patient's Steady
feed beside the psychologist's consult note. Sorted's side is described in its
`docs/integrations/steady.md`; this is Steady's side.

## Switching it on

1. Make a key: `openssl rand -hex 32`.
2. Put it in Steady's `deploy/.env` as `STEADY_INTEGRATION_KEY=...` and run `sudo ./update.sh`
   (or `docker compose up -d`).
3. Put the same key and Steady's address in Sorted's `.env` (main server and standby):
   `STEADY_URL=https://steady.openworks.co.za` and `STEADY_API_KEY=...`.

Without a key (fewer than 32 characters) the endpoints don't exist (404).

## The endpoints

Both are read only and need:

- `Authorization: Bearer <key>` (compared in constant time), and
- `X-Steady-Clinician: <email>`: the psychologist Sorted is acting for. Only that psychologist's
  **own** patients are returned; patients shared with them are not. An unknown email, a stopped
  account or someone else's patient gets 404.

Every call is written to Steady's audit log (`integration.patients`, `integration.feed`, with the
date range and the patient) and rate limited (120 a minute).

### `GET /api/steady/integration/patients`

```json
{ "patients": [ { "id": "abc123", "name": "Megan A.", "joinedAt": "2026-08-01T09:00:00.000Z", "active": true } ] }
```

`name` is what the psychologist calls the patient (the invite name), as in the app.

### `GET /api/steady/integration/patients/{id}/feed?from=YYYY-MM-DD&to=YYYY-MM-DD`

At most 400 days; the default is the last 28. The shape is Sorted's `SteadyFeed`: `patient`,
`from`, `to`, `checkins` (with the patient's note), `assessments` (total, max, band, severity,
flags), `exercises`, `flags`, `pending`, and `wearable` (`connected`, `days`, only while the
patient's watch consent is on). Item-level answers are left out on purpose.

## Privacy

The feed goes to the same practice, for the same purpose: the patient's care by their
psychologist. Steady's consent statement should say that check-ins and scores can appear in the
practice's clinical record system. Keep the key in the two servers' settings only; if it leaks,
make a new one on both.
