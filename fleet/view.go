// Turns a server's answer into what the pages show.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"fmt"
	"math"
	"strings"
	"time"
)

// get walks a JSON object: get(m, "host", "disk", "used").
func get(m map[string]any, path ...string) any {
	var cur any = m
	for _, k := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}

func num(v any) (float64, bool) {
	f, ok := v.(float64)
	return f, ok && !math.IsNaN(f)
}

func str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// Row is one server on the overview.
type Row struct {
	Index                     int
	Name, URL, Domain         string
	Level                     string // good, slow, struggling, down
	Health                    string
	Version, VersionNote      string
	Behind                    bool
	Disk, Memory              string
	DiskWarn                  bool
	Backup                    string
	BackupWarn                bool
	Patients, Staff, Checkins string
	Busy                      string // a request waiting, an update or restart under way
	Audit                     Audit  // the latest security and privacy check
	Err                       string
	Checked                   string
	CanAct                    bool
}

func ago(t time.Time, now time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%d days ago", int(d.Hours()/24))
	}
}

func parseTime(v any) time.Time {
	t, _ := time.Parse(time.RFC3339, str(v))
	return t
}

func intText(v any) string {
	if f, ok := num(v); ok {
		return fmt.Sprintf("%d", int64(f))
	}
	return "?"
}

func bytesText(b float64) string {
	const gb = 1 << 30
	if b >= gb {
		return fmt.Sprintf("%.1f GB", b/gb)
	}
	return fmt.Sprintf("%.0f MB", b/(1<<20))
}

func makeRow(i int, st *Status, now time.Time) Row {
	r := Row{Index: i, Name: st.Server.Name, URL: st.Server.URL}
	r.Domain = strings.TrimPrefix(strings.TrimPrefix(st.Server.URL, "https://"), "http://")
	r.Checked = ago(st.At, now)
	if st.Err != "" || st.Data == nil {
		r.Level, r.Health, r.Err = "down", "unreachable", st.Err
		if r.Err == "" {
			r.Err = "no answer yet"
		}
		return r
	}
	d := st.Data
	if p := str(d["practice"]); p != "" && r.Name == "" {
		r.Name = p
	}
	r.Level = str(get(d, "health", "status"))
	if r.Level == "" {
		r.Level = "good"
	}
	r.Health = r.Level
	if reasons, ok := get(d, "health", "reasons").([]any); ok && len(reasons) > 0 {
		var rs []string
		for _, x := range reasons {
			rs = append(rs, str(x))
		}
		r.Health += ": " + strings.Join(rs, ", ")
	}
	// version: the code it runs, and whether a newer signed release is waiting
	code := str(get(d, "version", "code"))
	if code == "" {
		code = "?"
	}
	r.Version = code
	// the buttons need the server's in-app updates (deploy/ctl/install.sh)
	r.CanAct = get(d, "version", "managed") == true
	if b, ok := num(get(d, "version", "behind")); ok && b > 0 {
		r.Behind = true
		r.VersionNote = fmt.Sprintf("%d change(s) behind", int(b))
	} else if get(d, "version", "managed") == false {
		r.VersionNote = "updates from the app not set up (ctl/install.sh)"
	} else if get(d, "version", "signed") == false {
		r.VersionNote = "unsigned: follows a branch"
	} else {
		r.VersionNote = "up to date"
	}
	if e := str(get(d, "version", "error")); e != "" {
		r.VersionNote = "last check failed: " + e
	}
	// disk and memory
	if total, ok := num(get(d, "host", "disk", "total")); ok && total > 0 {
		used, _ := num(get(d, "host", "disk", "used"))
		pct := used / total * 100
		r.Disk = fmt.Sprintf("%.0f%% of %s", pct, bytesText(total))
		r.DiskWarn = pct > 80
	} else {
		r.Disk = "?"
	}
	if total, ok := num(get(d, "host", "memory", "total")); ok && total > 0 {
		avail, _ := num(get(d, "host", "memory", "available"))
		r.Memory = fmt.Sprintf("%.0f%% used", (total-avail)/total*100)
	} else {
		r.Memory = "?"
	}
	// backups: the newest nightly backup's age
	if nb := parseTime(get(d, "host", "backups", "newest")); !nb.IsZero() {
		r.Backup = ago(nb, now)
		r.BackupWarn = now.Sub(nb) > 36*time.Hour
	} else {
		r.Backup, r.BackupWarn = "none found", true
	}
	r.Audit = makeAudit(d, now)
	r.Patients = intText(get(d, "counts", "patients"))
	r.Staff = intText(get(d, "counts", "staff"))
	r.Checkins = intText(get(d, "counts", "checkins7d"))
	switch {
	case get(d, "updating") != nil:
		r.Busy = "updating: " + str(get(d, "updating", "step"))
	case str(d["pending"]) != "":
		r.Busy = "waiting to " + str(d["pending"])
	}
	return r
}

// Facts are the detail page's label/value pairs.
type Fact struct{ Label, Value string }

func facts(st *Status, now time.Time) []Fact {
	d := st.Data
	if d == nil {
		return nil
	}
	f := []Fact{
		{"Practice", str(d["practice"])},
		{"Address", st.Server.URL},
		{"Running for", durationText(get(d, "uptimeSeconds"))},
		{"Code", str(get(d, "version", "code"))},
		{"Latest signed release", str(get(d, "version", "latest", "release")) + " " + str(get(d, "version", "latest", "sha"))},
		{"Last update check", ago(parseTime(get(d, "version", "checkedAt")), now)},
		{"Android app on the server", str(get(d, "version", "app", "current"))},
		{"Requests, last hour", intText(get(d, "lastHour", "requests")) + " (typical " + msText(get(d, "lastHour", "p50")) + ", slowest 5% " + msText(get(d, "lastHour", "p95")) + ")"},
		{"Server errors, last 24 h", intText(get(d, "last24h", "errors"))},
		{"Database", bytesOrQ(get(d, "database", "bytes"))},
		{"CPU load (1, 5, 15 min)", loadText(get(d, "host", "load"))},
		{"Backups", intText(get(d, "host", "backups", "count")) + " files, " + bytesOrQ(get(d, "host", "backups", "bytes"))},
		{"Staff sign-in by email code", yesNo(get(d, "signIn", "linkedDevices"))},
		{"Deletion requests waiting", intText(get(d, "counts", "deletionRequests"))},
		{"Operator agreement", agreementText(get(d, "operatorAgreement"))},
	}
	if lu, ok := d["lastUpdate"].(map[string]any); ok {
		res := "worked"
		if lu["ok"] == false {
			res = "FAILED: " + str(lu["message"])
		}
		f = append(f, Fact{"Last update", ago(parseTime(lu["at"]), now) + ", " + res})
	}
	if lr, ok := d["lastRestart"].(map[string]any); ok {
		res := "worked"
		if lr["ok"] == false {
			res = "FAILED"
		}
		f = append(f, Fact{"Last restart", ago(parseTime(lr["at"]), now) + ", " + res})
	}
	return f
}

func msText(v any) string {
	if f, ok := num(v); ok {
		return fmt.Sprintf("%.0f ms", f)
	}
	return "?"
}

func bytesOrQ(v any) string {
	if f, ok := num(v); ok {
		return bytesText(f)
	}
	return "?"
}

// agreementText: whether the practice signed the current operator agreement (Steady 1.0.5 on).
func agreementText(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return "?"
	}
	if m["signed"] == true {
		at := parseTime(m["signedAt"])
		if at.IsZero() {
			return "signed, version " + str(m["version"])
		}
		return "signed, version " + str(m["version"]) + ", on " + at.Format("2 Jan 2006")
	}
	if last := str(m["lastSignedVersion"]); last != "" {
		return "NOT SIGNED: version " + str(m["version"]) + " waits for the master clinician (version " + last + " was signed)"
	}
	return "NOT SIGNED: version " + str(m["version"]) + " waits for the master clinician"
}

func yesNo(v any) string {
	if b, ok := v.(bool); ok {
		if b {
			return "yes"
		}
		return "no"
	}
	return "?"
}

func loadText(v any) string {
	l, ok := v.([]any)
	if !ok {
		return "?"
	}
	var s []string
	for _, x := range l {
		if f, ok := num(x); ok {
			s = append(s, fmt.Sprintf("%.2f", f))
		}
	}
	return strings.Join(s, ", ")
}

func durationText(v any) string {
	f, ok := num(v)
	if !ok {
		return "?"
	}
	d := time.Duration(f) * time.Second
	if d > 48*time.Hour {
		return fmt.Sprintf("%d days", int(d.Hours()/24))
	}
	return fmt.Sprintf("%d h %d min", int(d.Hours()), int(d.Minutes())%60)
}

// Check is one line of a server's security and privacy check (deploy/audit-server.sh).
type Check struct{ Level, Section, Text string }

// Audit is a server's latest security and privacy check, run on the server every 6 hours by the
// steady-audit service and handed over with its status (docs/FLEET.md), plus the privacy numbers
// the server counts itself.
type Audit struct {
	Have                  bool
	Checked, Code         string
	Stale                 bool
	Fails, Warns, Oks     int
	Problems, Passed      []Check
	OlderConsent          string
	DeletionOverdue       string
	StaffWithoutTwoStep   string
	PrivacyWarn           bool
	Summary, SummaryClass string // for the overview: "2 to fix, 3 to look at" and good, warn or bad
	PrivacyNote           string // for the overview: the privacy numbers that aren't zero
}

// auditStale: the check runs every 6 hours; much older means the service stopped.
const auditStale = 13 * time.Hour

func makeAudit(d map[string]any, now time.Time) Audit {
	a := Audit{}
	// privacy numbers (Steady 1.0.6 on): what isn't zero is worth a look
	var notes []string
	for _, p := range []struct {
		key  string
		dst  *string
		note string
	}{
		{"olderConsent", &a.OlderConsent, "on an older consent statement"},
		{"deletionOverdue", &a.DeletionOverdue, "deletion past 25 days"},
		{"staffWithoutTwoStep", &a.StaffWithoutTwoStep, "staff without two-step sign-in"},
	} {
		v := get(d, "counts", p.key)
		*p.dst = intText(v)
		if n, ok := num(v); ok && n > 0 {
			a.PrivacyWarn = true
			notes = append(notes, fmt.Sprintf("%d %s", int(n), p.note))
		}
	}
	a.PrivacyNote = strings.Join(notes, ", ")
	m, ok := d["audit"].(map[string]any)
	if !ok {
		a.Summary, a.SummaryClass = "no check yet", "muted"
		return a
	}
	a.Have = true
	at := parseTime(m["at"])
	a.Checked = ago(at, now)
	a.Stale = at.IsZero() || now.Sub(at) > auditStale
	a.Code = str(m["code"])
	if items, ok := m["items"].([]any); ok {
		var fails, warns []Check
		for _, x := range items {
			it, ok := x.(map[string]any)
			if !ok {
				continue
			}
			c := Check{Level: str(it["level"]), Section: str(it["section"]), Text: str(it["text"])}
			switch c.Level {
			case "fail":
				fails = append(fails, c)
			case "warn":
				warns = append(warns, c)
			case "ok":
				a.Passed = append(a.Passed, c)
			}
		}
		a.Fails, a.Warns, a.Oks = len(fails), len(warns), len(a.Passed)
		a.Problems = append(fails, warns...)
	}
	switch {
	case a.Fails > 0:
		a.Summary, a.SummaryClass = fmt.Sprintf("%d to fix, %d to look at", a.Fails, a.Warns), "bad"
	case a.Warns > 0:
		a.Summary, a.SummaryClass = fmt.Sprintf("%d to look at", a.Warns), "warn"
	default:
		a.Summary, a.SummaryClass = "all clear", "good"
	}
	if a.Stale {
		a.Summary += " (" + a.Checked + ": the check has stopped running)"
		if a.SummaryClass == "good" {
			a.SummaryClass = "warn"
		}
	}
	return a
}
