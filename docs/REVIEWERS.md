# The app stores' reviewers (test server only)

Apple and Google review Steady with logins on OpenWorks' test server. A patient's login shows
the patient's side only. The watch data a patient shares (heart rate, sleep, steps, blood
oxygen) shows on the psychologist's side: daily charts in the patient's record, and RADR.
Google wants to see each Health Connect data type in use, so reviewers need a psychologist's
login too. They can't use an authenticator app or receive the emailed device code, so this
account signs in with its password alone.

**This lives on the test branch only.** It never goes to main, so no practice's server has
it. When test goes to main, leave these changes out: `server/pb_hooks/steady_reviewers.pb.js`,
`reviewer()` in `lib/server.js` and its three uses (two-step, the device code at sign-in, the
community), `accounts.sh reviewer`, `STEADY_REVIEWERS` in `docker-compose.yml`, its test in
`hooks.test.js`, and this page.

## What the account is

- A psychologist marked demo, with three fictional patients (`accounts.sh demo-patients`) that
  have watch data, check-ins and questionnaires. With `STEADY_DEMO_DAILY=on` they get a new day
  every night.
- It signs in with its password alone, only where the server has `STEADY_REVIEWERS=on`.
  Anywhere else it would need two-step sign-in like every other psychologist, so it can't sign in.
- It sees only its own fictional patients. It isn't the master psychologist, and the community
  doesn't open for it.
- Its password, email and sign-in can't be changed from the app, so one reviewer can't lock
  the next one out.
- Patients' and real psychologists' sign-in doesn't change.

## Setting it up

On vps1, in the test server's folder:

```
cd /opt/steady/deploy
grep -q '^STEADY_REVIEWERS=' .env || echo 'STEADY_REVIEWERS=on' | sudo tee -a .env
sudo docker compose up -d
sudo ./accounts.sh reviewer review@openworks.co.za
```

It prints the password and the fictional patients. Run it again for a new password: the old one
stops working. `sudo ./accounts.sh list` shows it as the app store reviewer.

## What to give the stores

- **Google Play:** Play Console > App content > App access. Choose "All or some functionality is
  restricted" and add two sets of instructions: the patient's login, and this psychologist's
  login. Say the server is `test.steadyapp.co.za`, that the data is fictional, and where the
  watch data shows: Patients > a patient > Wearable for the daily charts, and the RADR tab next to it.
- **Apple:** App Store Connect > the version > App Review Information. Use the same two logins
  and notes.

## Stopping it

```
sudo ./accounts.sh reviewer review@openworks.co.za --remove
```

That stops the account and removes its fictional patients. For good, also take
`STEADY_REVIEWERS=on` out of `.env` and run `sudo docker compose up -d`.
