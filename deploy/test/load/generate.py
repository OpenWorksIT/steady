"""Synthetic psychiatry-scale caseload for load testing Steady. Fictional data only: never run
this against a real practice's database. See docs/CAPACITY.md.
usage: generate.py DB CLINICIAN_ID N_PATIENTS DAYS [SEED]
  20% of patients check in most days, 50% about weekly, 30% about monthly; 25% share watch
  data; everyone completes a PHQ-9 every 30 days.
SPDX-License-Identifier: AGPL-3.0-or-later"""
import sqlite3, random, string, json, sys, datetime as dt, bcrypt
db, cid, n, days = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rnd = random.Random(int(sys.argv[5]) if len(sys.argv) > 5 else 7)
c = sqlite3.connect(db)
PHQ = c.execute("select id from instruments where key='phq9'").fetchone()[0]
now = dt.datetime(2026, 10, 23, 12, 0, tzinfo=dt.timezone.utc)
def rid(): return "".join(rnd.choice(string.ascii_lowercase + string.digits) for _ in range(15))
def ts(d): return d.strftime("%Y-%m-%d %H:%M:%S.000Z")
pw = bcrypt.hashpw(b"x-not-a-login-x", bcrypt.gensalt(4)).decode()
notes = ["Good day at work.", "Slept badly, anxious about the appointment.", "Felt flat most of the day.", "Better than yesterday.",
         "Took my medication late again.", "Busy week, tired but okay.", "Hard to get going this morning."]
users, cks, bios, asg = [], [], [], []
for i in range(n):
    pid = rid()
    joined = now - dt.timedelta(days=rnd.randint(14, days))
    watch = rnd.random() < 0.25
    prof = rnd.random()
    p_ck = 0.85 if prof < 0.2 else (1 / 7 if prof < 0.7 else 1 / 30)
    users.append((pid, ts(joined), ts(joined), f"p{i}.{pid}@load.test", 0, f"Load patient {i}", pw, rid() + rid(), 1, "patient", cid, 1,
                  ts(joined), "v1", 120, ts(joined) if watch else "", "v1" if watch else "", f"LP-{i}", 0, 0, 0, "", "", 0, "[]", "[]", 0))
    span = (now - joined).days
    for d in range(span):
        day = joined + dt.timedelta(days=d)
        if rnd.random() < p_ck:
            at = day.replace(hour=18, minute=rnd.randint(0, 59))
            m = rnd.randint(1, 5)
            cks.append((rid(), ts(at), ts(at), pid, m, rnd.randint(1, 5), rnd.randint(1, 5), rnd.randint(1, 5),
                        rnd.choice(notes) if rnd.random() < 0.4 else ""))
        if watch and rnd.random() < 0.9:
            dd = day.strftime("%Y-%m-%d")
            v = {"hr_avg": rnd.randint(62, 85), "hr_max": rnd.randint(110, 160), "hr_min": rnd.randint(45, 60), "hr_samples": rnd.randint(300, 1400),
                 "rhr": round(rnd.uniform(52, 72), 1), "rhr_method": "sleep", "sleep_awake": rnd.randint(5, 60), "sleep_deep": rnd.randint(40, 110),
                 "sleep_light": rnd.randint(180, 300), "sleep_min": rnd.randint(330, 520), "sleep_onset": rnd.randint(-120, 60),
                 "sleep_rem": rnd.randint(60, 130), "sleep_wake": rnd.randint(330, 480), "spo2_avg": rnd.randint(94, 99), "spo2_min": rnd.randint(88, 94),
                 "steps": rnd.randint(1500, 14000)}
            bios.append(("rhr-v1", ts(day.replace(hour=7)), dd, rid(), pid, "android", "Health Connect", ts(day.replace(hour=7)), json.dumps(v)))
        if d % 30 == 15:
            at = day.replace(hour=9)
            ans = {f"phq9_{k}": rnd.randint(0, 3) for k in range(1, 10)}
            tot = sum(ans.values())
            asg.append(("", cid, ts(at), ts(at), rid(), PHQ, "", pid, "", json.dumps({"answers": ans, "version": "1"}),
                        json.dumps({"band": "Moderate", "bandSeverity": "warn", "flags": [], "max": 27, "note": "", "severity": "warn", "subscales": [], "total": tot}),
                        0, "done", ts(at)))
c.executemany("insert into users (id,created,updated,email,emailVisibility,name,password,tokenKey,verified,role,clinician,active,consentAt,consentVersion,tzOffset,wearableConsentAt,wearableConsentVersion,clinicianLabel,serverAdmin,master,mustChangePassword,totpSecret,totpEnabledAt,totpLastStep,recoveryCodes,sharedWith,demo) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", users)
c.executemany("insert into checkins (id,created,updated,patient,mood,anxiety,sleep,energy,note) values (?,?,?,?,?,?,?,?,?)", cks)
c.executemany('insert into biometrics (algorithm,created,day,id,patient,platform,source,updated,"values") values (?,?,?,?,?,?,?,?,?)', bios)
c.executemany("insert into assignments (availableFrom,clinician,completedAt,created,id,instrument,note,patient,repeat,result,score,selfStarted,status,updated) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", asg)
c.commit()
print(f"patients {len(users)}  checkins {len(cks)}  watch days {len(bios)}  questionnaires {len(asg)}")
