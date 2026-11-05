# Steady's versions

One number for the whole of Steady: the practice servers, the web app, the Android app on the
servers, and the store apps. It is set in `VERSION` at the top of the repository.

- **A large update adds .1**: 1.0.5 becomes **1.1.0**.
- **A small update adds .0.1**: 1.0.5 becomes **1.0.6**.
- **1.0.0** is the version VR Clinical Psychology's own server (vps2) started on, 30 October 2026.
  Everything before it was the beta, and counts as **0.9 and earlier**.

What people see:

| Where | Shows |
|---|---|
| A signed release, on a practice's server | `1.0.5` |
| Work on its way to a release (the test server, vps1) | `1.1.0 test 23`: heading for 1.1.0, 23 changes after the last release |
| The app (Settings, Server and updates) | its own version, the server's, the newest release, what's in testing, and the store apps |
| The fleet view | each server's version; a server from before versions shows its release's number when it runs the latest one |

`deploy/version.sh` works out the version of any commit the same way everywhere (CI, the
servers, the security check).

## Making a release

1. In a pull request into working: set `VERSION`, and the same number in `app/pubspec.yaml`
   (`version: 1.1.0+110`; the part after `+` doesn't matter, CI sets it). CI refuses the pull
   request if the two differ.
2. It goes through test (vps1) to main as usual.
3. On your own computer, once the "Test builds" run for main has finished: `deploy/release.sh`.
   It signs `v1.1.0` only if `VERSION` on main says 1.1.0, the number is higher than every
   release so far, and CI's web build of that commit is marked 1.1.0.

## The store apps

`app/stores.json` says which version each store has, and since when. Change it by hand when a
store approves a new version (`status`: `in review`, `live`, or `testing` for TestFlight). The
servers read it from main and show it under Settings > Server and updates, so it is there for
OpenWorks to keep track; it changes nothing else. Store builds take their version from
`VERSION` (Actions > Store builds, and iOS builds).

## So far

| Version | Date | What |
|---|---|---|
| 0.9 and earlier | 14 to 29 Oct 2026 | The beta: the first build, then the beta on a laptop test server, then on vps1 |
| 1.0.0 | 30 Oct 2026 | VR's own server (vps2). The 1.0 security audit and penetration tests, signed releases, the access log, exports for AI note-taking |
| 1.0.2 | 30 Oct 2026 | Patients can ask to delete their account in the app; the source code link and credits (1.0.1 was never released on its own) |
| 1.0.4 | 3 Nov 2026 | Fixes from the November security review; patients agree again when the consent statement changes; the fleet view (1.0.3 was never released on its own) |
| 1.0.5 | 3 Nov 2026 | Server updates from the app fixed; branches main, test and working; Caddy pinned; the dependency check |
| 1.1.0 | 5 Nov 2026 | The operator agreement, Android notifications through Google, live security and privacy checks in the fleet view, the Community tab, version numbers, Settings as a page |
| 1.1.1 | next | Changing your own email address; the fleet view flags a server whose security check isn't running; OpenWorks opens the community only from its own server, and reads The science |
