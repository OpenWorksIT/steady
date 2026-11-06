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
	Name, URL, Domain, Short  string // Short: the name fleet.sh takes ("vr")
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
	r := Row{Index: i, Name: st.Server.Name, URL: st.Server.URL, Short: st.Server.ShortName()}
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
	// version: what it runs, as people read it, and whether a newer signed release is waiting
	r.Version = versionText(d)
	// the commands need the server's in-app updates (deploy/ctl/install.sh)
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

// versionText: the version a server runs as people read it ("1.0.5", "1.1.0 test 23"; see
// deploy/version.sh). A server from before versions were reported shows its release's number
// when it runs the latest signed release, and its code otherwise.
func versionText(d map[string]any) string {
	if v := str(get(d, "version", "current", "version")); v != "" {
		return v
	}
	code := str(get(d, "version", "code"))
	latest, rel := str(get(d, "version", "latest", "sha")), str(get(d, "version", "latest", "release"))
	if code != "" && rel != "" && strings.HasPrefix(latest, code) {
		return strings.TrimPrefix(rel, "v")
	}
	if code == "" {
		return "?"
	}
	return code
}

// releaseText: the newest signed release ("1.0.5"), or "none" for a server that follows a branch.
func releaseText(d map[string]any) string {
	rel := strings.TrimPrefix(str(get(d, "version", "latest", "release")), "v")
	if rel == "" {
		return "none (follows a branch)"
	}
	return rel
}

func firstOf(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}

func facts(st *Status, now time.Time) []Fact {
	d := st.Data
	if d == nil {
		return nil
	}
	f := []Fact{
		{"Practice", str(d["practice"])},
		{"Address", st.Server.URL},
		{"Running for", durationText(get(d, "uptimeSeconds"))},
		{"Version", versionText(d)},
		{"Code", str(get(d, "version", "code"))},
		{"Latest signed release", releaseText(d)},
		{"Last update check", ago(parseTime(get(d, "version", "checkedAt")), now)},
		{"Android app on the server", firstOf(str(get(d, "version", "app", "currentVersion")), str(get(d, "version", "app", "current")))},
		{"Requests, last hour", intText(get(d, "lastHour", "requests")) + " (typical " + msText(get(d, "lastHour", "p50")) + ", slowest 5% " + msText(get(d, "lastHour", "p95")) + ")"},
		{"Server errors, last 24 h", intText(get(d, "last24h", "errors"))},
		{"Database", bytesOrQ(get(d, "database", "bytes"))},
		{"CPU load (1, 5, 15 min)", loadText(get(d, "host", "load"))},
		{"Backups", intText(get(d, "host", "backups", "count")) + " files, " + bytesOrQ(get(d, "host", "backups", "bytes"))},
		{"Staff sign-in by email code", yesNo(get(d, "signIn", "linkedDevices"))},
		{"Deletion requests waiting", intText(get(d, "counts", "deletionRequests"))},
		{"Operator agreement", agreementText(get(d, "operatorAgreement"))},
		{"Feedback waiting", feedbackText(d, now)},
		{"OpenWorks support accounts", intText(get(d, "counts", "supportAccounts"))},
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

// feedbackText: how many reports wait and since when, never what they say (the practice reads
// them in Settings > Practice; OpenWorks with deploy/feedback.sh on the server).
func feedbackText(d map[string]any, now time.Time) string {
	n := get(d, "counts", "feedbackNew")
	if n == nil {
		return "?"
	}
	if f, _ := n.(float64); f == 0 {
		return "none"
	}
	t := intText(n) + " new"
	if b, _ := get(d, "counts", "feedbackNewBugs").(float64); b > 0 {
		t += fmt.Sprintf(" (%d bug report%s)", int(b), map[bool]string{true: "", false: "s"}[b == 1])
	}
	if at := parseTime(d["feedbackOldestNew"]); !at.IsZero() {
		t += ", the oldest " + ago(at, now)
	}
	return t
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
	Down, Fix             string // why the check isn't running on the server ("" when it is: a red flag), and the command that sees to it
	Running               bool   // a check is under way right now
	NextRun               string // when the timer runs it next ("in 3 h"), if the server says
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
	svc, _ := get(d, "host", "auditService").(map[string]any)
	if svc != nil {
		a.Running = str(svc["state"]) == "activating"
		if next := parseTime(svc["nextRun"]); next.After(now.Add(time.Minute)) {
			a.NextRun = "in " + strings.TrimSuffix(ago(now.Add(-next.Sub(now)), now), " ago")
		}
	}
	m, ok := d["audit"].(map[string]any)
	if ok {
		a.Have = true
		at := parseTime(m["at"])
		a.Checked = ago(at, now)
		a.Stale = at.IsZero() || now.Sub(at) > auditStale
		a.Code = str(m["code"])
	}
	a.Down, a.Fix = auditDown(a, svc, now)
	switch {
	case a.Down != "":
		a.Summary, a.SummaryClass = "check not running", "bad"
	case !a.Have && a.Running:
		a.Summary, a.SummaryClass = "first check running", "muted"
	case !a.Have:
		// installed and switched on, but it hasn't run yet: install.sh starts the first one
		a.Summary, a.SummaryClass = "no check yet", "muted"
	}
	if !a.Have {
		return a
	}
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
	case a.Down != "":
		// the findings below are from the last check that ran, however old
	case a.Fails > 0:
		a.Summary, a.SummaryClass = fmt.Sprintf("%d to fix, %d to look at", a.Fails, a.Warns), "bad"
	case a.Warns > 0:
		a.Summary, a.SummaryClass = fmt.Sprintf("%d to look at", a.Warns), "warn"
	default:
		a.Summary, a.SummaryClass = "all clear", "good"
	}
	return a
}

// installCmd sets up (or repairs) the check on a practice server.
const installCmd = "cd /opt/steady/deploy && sudo ./ctl/install.sh"

// auditDown says why a server's security and privacy check isn't running, and the command to
// run on the server, or "" when it is running. svc is what the server's stats step saw of the
// check's timer (host.auditService, Steady 1.1.1 on); nil from older servers, which are judged
// by their results alone.
func auditDown(a Audit, svc map[string]any, now time.Time) (why, fix string) {
	const logs = "sudo journalctl -u steady-audit -n 50 --no-pager"
	if svc != nil {
		timer := str(svc["timer"])
		result := str(svc["result"])
		switch {
		case svc["installed"] == false:
			return "the check isn't installed on this server", installCmd
		case svc["enabled"] == false || (timer != "" && timer != "active"):
			return "the check's timer is switched off", installCmd
		case !a.Running && result != "" && result != "success":
			last := ago(parseTime(svc["lastRun"]), now)
			return fmt.Sprintf("the last check failed (%s, exit %s, %s)", result, intText(svc["exitStatus"]), last), logs
		}
	}
	switch {
	case a.Running:
		return "", ""
	case !a.Have && svc != nil && str(svc["lastRun"]) != "":
		return "the check ran " + ago(parseTime(svc["lastRun"]), now) + " but Steady can't read its results (/var/lib/steady/ctl/out/audit.json)", installCmd
	case !a.Have && svc == nil:
		return "no check from this server", installCmd
	case a.Stale:
		return "the check last ran " + a.Checked + " and has stopped", "systemctl status steady-audit.timer steady-audit.service --no-pager; " + logs
	}
	return "", ""
}

// DownText is the red flag in one line, for the checks page and the overview's tooltip.
func (a Audit) DownText() string {
	if a.Down == "" {
		return ""
	}
	return a.Down + ": " + a.Fix
}

// FeedItem is one finding on the checks page, with the server it's on.
type FeedItem struct {
	Index                                 int
	Server, Level, Section, Text, Checked string
	Link                                  string // where its name leads: the server's checks, or the overview's own services
}

// ServerChecks is one server's line on the checks page: its counts and a bar of them.
type ServerChecks struct {
	Index                 int
	Name, Checked         string
	Fix, Look, Passed     int
	FixW, LookX, LookW    string // the bar's parts, in % of its width (SVG attributes, not styles)
	Summary, SummaryClass string
}

// ChecksPage is every server's security and privacy checks, by severity: what to fix on any
// server first, then what to look at. The privacy numbers each server counts become findings
// too, and so do a server the fleet view can't reach and a check that has stopped running.
type ChecksPage struct {
	Servers   []ServerChecks
	Fix, Look []FeedItem
	Passed    int
}

func makeChecks(sts []*Status, cst *CommunityStatus, now time.Time) ChecksPage {
	var p ChecksPage
	// OpenWorks' own services first: the fleet view and the sign-in bridge running other code
	// than their release
	for _, o := range ownServices(sts, cst) {
		if o.Level == "good" {
			continue
		}
		text := o.Note
		if o.Fix != "" {
			text += ": " + o.Fix
		}
		it := FeedItem{Server: o.Name, Section: "Code", Text: "runs " + o.Runs + ": " + text, Link: "/#code"}
		if o.Level == "bad" {
			it.Level = "fail"
			p.Fix = append(p.Fix, it)
		} else {
			it.Level = "warn"
			p.Look = append(p.Look, it)
		}
	}
	for i, st := range sts {
		row := makeRow(i, st, now)
		sc := ServerChecks{Index: i, Name: row.Name}
		add := func(level, section, text, checked string) {
			it := FeedItem{Index: i, Server: row.Name, Level: level, Section: section, Text: text, Checked: checked, Link: fmt.Sprintf("/s/%d#checks", i)}
			if level == "fail" {
				p.Fix = append(p.Fix, it)
				sc.Fix++
			} else {
				p.Look = append(p.Look, it)
				sc.Look++
			}
		}
		if row.Err != "" {
			add("fail", "Reaching it", row.Err, row.Checked)
			sc.Checked, sc.Summary, sc.SummaryClass = row.Checked, "can't be reached", "bad"
			p.Servers = append(p.Servers, sc.withBar())
			continue
		}
		// feedback nobody has looked at for a week (counts only: never what it says)
		if n, _ := get(st.Data, "counts", "feedbackNew").(float64); n > 0 {
			if at := parseTime(st.Data["feedbackOldestNew"]); !at.IsZero() && now.Sub(at) > 7*24*time.Hour {
				add("warn", "Feedback", fmt.Sprintf("%d feedback report(s) waiting, the oldest %s: the practice reads them in Settings > Practice; OpenWorks with sudo ./feedback.sh on the server", int(n), ago(at, now)), row.Checked)
			}
		}
		// OpenWorks' own accounts aren't needed on a practice's server any more (the fleet resets passwords)
		if n, _ := get(st.Data, "counts", "supportAccounts").(float64); n > 0 && st.Data["openworksServer"] != true {
			add("warn", "Accounts", fmt.Sprintf("%d OpenWorks support account(s) on a practice's server: no longer needed, since passwords are reset from the fleet view. Stop each one there: sudo ./accounts.sh set <its email> active off", int(n)), row.Checked)
		}
		// a practice server on an older signed release (a server following a branch is left alone)
		if row.Behind && get(st.Data, "version", "signed") != false {
			add("warn", "Version", fmt.Sprintf("runs %s, %s the newest signed release (%s): Update on its page", row.Version, row.VersionNote, releaseText(st.Data)), row.Checked)
		}
		a := row.Audit
		sc.Checked = a.Checked
		if !a.Have {
			sc.Checked = "never"
		}
		if a.Down != "" {
			add("fail", "The check", a.DownText(), sc.Checked)
		} else if !a.Have && a.Running {
			add("warn", "The check", "no security and privacy check from this server yet: the first one is running", "")
		} else if !a.Have {
			add("warn", "The check", "no security and privacy check from this server yet: it's installed and waits for its first run", "")
		}
		privacy := []struct {
			key, level, text string
		}{
			{"deletionOverdue", "fail", "%d deletion request(s) past 25 days: the practice has 30 days to carry them out"},
			{"olderConsent", "warn", "%d patient(s) haven't yet agreed to the current consent statement (asked the next time they open Steady)"},
			{"staffWithoutTwoStep", "warn", "%d staff member(s) without two-step sign-in (accounts.sh list)"},
		}
		for _, x := range privacy {
			if n, ok := num(get(st.Data, "counts", x.key)); ok && n > 0 {
				add(x.level, "Privacy", fmt.Sprintf(x.text, int(n)), row.Checked)
			}
		}
		for _, c := range a.Problems {
			add(c.Level, c.Section, c.Text, a.Checked)
		}
		sc.Passed = a.Oks
		p.Passed += a.Oks
		switch {
		case sc.Fix > 0:
			sc.Summary, sc.SummaryClass = fmt.Sprintf("%d to fix, %d to look at", sc.Fix, sc.Look), "bad"
		case sc.Look > 0:
			sc.Summary, sc.SummaryClass = fmt.Sprintf("%d to look at", sc.Look), "warn"
		default:
			sc.Summary, sc.SummaryClass = "all clear", "good"
		}
		p.Servers = append(p.Servers, sc.withBar())
	}
	return p
}

// withBar works out the bar: to fix, then to look at, then passed, in proportion.
func (sc ServerChecks) withBar() ServerChecks {
	total := sc.Fix + sc.Look + sc.Passed
	if total == 0 {
		sc.FixW, sc.LookX, sc.LookW = "0", "0", "0"
		return sc
	}
	pct := func(n int) float64 { return float64(n) * 100 / float64(total) }
	sc.FixW = fmt.Sprintf("%.2f", pct(sc.Fix))
	sc.LookX = sc.FixW
	sc.LookW = fmt.Sprintf("%.2f", pct(sc.Look))
	return sc
}
