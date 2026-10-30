# How much Steady can carry

Measured on 23 October 2026 with a synthetic psychiatry caseload (`deploy/test/load/`), one
PocketBase server pinned to one CPU core and then to two, roughly the speed of Rackzar's KLX1
and KLX2 (about 1 130 single-core score). Fictional data only.

**The test caseload:** one psychiatrist with 3 000 patients over up to a year: 20% check in most
days, 50% about weekly, 30% about monthly; 25% share watch data; everyone completes a PHQ-9
monthly. That came to 141 000 check-ins, 132 000 watch days and 19 000 questionnaires.

## Speed

| What | 1 core | 2 cores |
|---|---|---|
| Patient list, 3 000 patients | 3.5 s | 3.4 s |
| Patient list during an evening peak (300 check-ins arriving) | 4 to 6 s | 3.5 to 6 s |
| One patient's summary | 0.01 s | |
| RADR, 13 weeks | 0.23 s | |
| One patient's full export (a year, with RADR) | 1.0 s | |
| Check-ins accepted | about 1 800 a minute, median 0.13 s | about 1 900 a minute |
| Server memory after the tests | 326 MB | |

The patient list grows with the number of patients one psychiatrist has: about 1.15 ms per
patient on one core (1 000 patients about 1.2 s, 2 000 about 2.3 s, 5 000 about 6 s). How much
history each patient has does not slow it, nor does the size of the practice as a whole: the
list, the summaries and RADR only read recent weeks. Exports grow with the period chosen.

Two cores don't make one request faster; they let more people use the server at once, and
keep it responsive while an export or an update runs.

### 20 000 patients on one core

A second test, the same day: ten psychiatrists with 2 000 patients each (20 000 in all, 950 000
check-ins, 860 000 watch days, 127 000 questionnaires, a 681 MB database), one CPU core.

| What | 1 core |
|---|---|
| One psychiatrist's list of 2 000, with 20 000 on the server | 1.4 s |
| RADR, 13 weeks | 0.18 s |
| One patient's full export | 0.6 s |
| Check-ins, sustained (3 000 arriving 30 at a time) | about 8 900 a minute, median 0.16 s, all accepted |
| A psychiatrist's list while those check-ins arrive | 7 to 8 s (the single core is saturated) |
| Server memory | under 200 MB |

The practice's total doesn't slow a psychiatrist's list: 2 000 patients take the same time
whether the server holds 2 000 or 20 000. The earlier figure of about 1 800 check-ins a minute
was measured while a 3 000-patient list was being built on the same core.

Before these measurements the list stopped at 1 000 patients and took 8 s for 3 000, and RADR
took 1.5 s; both were fixed in the same change.

## Storage

| Record | On disk, with indexes |
|---|---|
| A watch day | 521 bytes |
| A check-in | 194 bytes |
| A questionnaire | 546 bytes |
| A patient | 458 bytes |

A fully engaged patient (watch every day, daily check-in, a weekly questionnaire) adds about
0.8 KB a day, 0.3 MB a year. The psychiatry mix above averaged 189 bytes per patient a day,
about 70 KB a year. The health log (deploy/health.sh) and notifications are trimmed
automatically and stay small.

The 20 000-patient test measured the same: 189 bytes per patient a day, 67 KB per patient a year,
so 20 000 such patients add about 1.4 GB a year.

On a 25 GB disk, after the operating system and Docker (about 5 GB), the five pre-update copies
of the data that `deploy/ctl` keeps (compressed, about a fifth of the database each) and 20%
free space, the database can grow to about 7 GB: some 23 000 fully engaged patient-years, or
100 000 patient-years of the psychiatry mix (20 000 such patients for about five years). On
60 GB, about 20 GB. In practice the disk fills from old Docker images (now cleaned up after
every update) and from backups kept on the server (keep those elsewhere).

## Safe operating limits

| Server | Patients per psychiatrist list | Patients per practice | Notes |
|---|---|---|---|
| KLX1 (1 core, 2 GB, 25 GB) | about 2 000 (list 1.4 s) | 20 000 (measured) | A psychology practice, or several psychiatrists |
| KLX2 (2 cores, 4 GB, 60 GB) | up to about 2 000 per psychiatrist | 20 000 or more | Several psychiatrists working at once; heavy exports don't hold others up |

Beyond about 2 000 active patients per psychiatrist, the list needs search-first or paging (a
planned change), not a bigger server. Bulk Excel exports from the app stop at 500 patients and
leave out RADR above 100; larger exports are done on the server.

## Watching it

`deploy/health.sh` (or Settings in the app: Server and updates for the master clinician and
OpenWorks support, Server health for the practice admin) shows the slowest 5% of requests, a database check every minute, errors,
database size, disk and memory. Move up a size when "typical requests" pass about a second, the
database check stays over 60 ms, or the disk passes 80%.

## Running the test again

```sh
cp -r <a test server's pb_data> /tmp/pbload/data
python3 deploy/test/load/generate.py /tmp/pbload/data/data.db <clinician id> 3000 365
# start PocketBase on 127.0.0.1:8098 with --dev=false, pinned with taskset -c 0 (or 0,1)
python3 deploy/test/load/evening_peak.py 300 20
```
