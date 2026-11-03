// The fleet view's to-do list: what OpenWorks IT has to do, look at or wait for (the practice
// servers, the community, the apps, the paperwork), and the monthly upkeep round
// (docs/UPKEEP.md), each with who did what and when. Kept in todo.json in the data folder.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// OpenWorks works in South African time (no daylight saving), whatever the container's clock.
var sast = time.FixedZone("SAST", 2*60*60)

// Entry is one line of an item's history, or one confirmation.
type Entry struct {
	At   time.Time `json:"at"`
	By   string    `json:"by"`
	Text string    `json:"text,omitempty"`
}

type Todo struct {
	ID       int       `json:"id"`
	Title    string    `json:"title"`
	Detail   string    `json:"detail,omitempty"`
	Area     string    `json:"area"`
	Priority string    `json:"priority"` // now, soon, later
	Status   string    `json:"status"`   // todo, look, waiting, done, dropped
	Waiting  string    `json:"waiting,omitempty"`
	Due      string    `json:"due,omitempty"` // YYYY-MM-DD
	Link     string    `json:"link,omitempty"`
	Created  Entry     `json:"created"`
	Changed  time.Time `json:"changed"`
	// done or dropped: who closed it, when, and what they said
	Closed  *Entry  `json:"closed,omitempty"`
	History []Entry `json:"history,omitempty"`
}

type TodoFile struct {
	Next  int    `json:"next"`
	Items []Todo `json:"items"`
	// month ("2026-11") → upkeep item key → who confirmed it, and when
	Upkeep map[string]map[string]Entry `json:"upkeep,omitempty"`
}

const (
	maxItems   = 2000
	maxHistory = 200
	maxTitle   = 120
	maxDetail  = 2000
	maxNote    = 1000
)

var priorities = []Choice{{"now", "Now"}, {"soon", "Soon"}, {"later", "Later"}}
var statuses = []Choice{{"todo", "On the list"}, {"look", "To look at"}, {"waiting", "Waiting"}, {"done", "Done"}, {"dropped", "Not doing"}}

// the areas the add form offers, before the practice servers' own names
var areas = []string{"OpenWorks", "Practice servers", "Test server (vps1)", "Community", "Apps and stores", "Releases", "Paperwork", "Mail and domains", "GitHub"}

type Choice struct{ Key, Label string }

func label(list []Choice, key string) string {
	for _, c := range list {
		if c.Key == key {
			return c.Label
		}
	}
	return ""
}

func isOpen(status string) bool { return status != "done" && status != "dropped" }

// UpkeepItem is one line of the monthly round in docs/UPKEEP.md. Keys never change: a month's
// confirmations are kept by key.
type UpkeepItem struct{ Key, Section, Text string }

var upkeepItems = []UpkeepItem{
	{"deps-look", "Updates to what Steady is built on", "Looked at what's waiting: Dependabot's pull requests, the latest Dependency check, the PocketBase and Caddy release pages."},
	{"deps-take", "Updates to what Steady is built on", "Each update worth taking went working → test → vps1, was used there, and was reviewed before going further."},
	{"deps-signed", "Updates to what Steady is built on", "No practice server updated from anything but a signed release."},
	{"srv-checks", "Each practice server", "The Checks page: all clear, or each item explained or fixed."},
	{"srv-release", "Each practice server", "On the newest signed release; the last update succeeded."},
	{"srv-health", "Each practice server", "Disk under 70 %, no memory or load trouble."},
	{"srv-backup", "Each practice server", "Last night's backup is there. Once a quarter: one restored to a scratch machine and opened."},
	{"srv-os", "Each practice server", "Automatic security updates on; a waiting reboot done outside practice hours."},
	{"srv-tls", "Each practice server", "The TLS certificate has more than 30 days left."},
	{"srv-staff", "Each practice server", "Staff all use two-step sign-in; accounts of people who left are stopped."},
	{"srv-agreement", "Each practice server", "The current operator agreement is signed."},
	{"srv-patients", "Each practice server", "Nobody who still uses Steady is on an older consent statement; no deletion request is older than 25 days."},
	{"srv-feedback", "Each practice server", "Each feedback ticket answered or planned."},
	{"vps1-same", "vps1: the test server and the forum", "The same checks as a practice server, where they apply."},
	{"vps1-track", "vps1: the test server and the forum", "It follows test and is on its newest commit."},
	{"vps1-disk", "vps1: the test server and the forum", "Free disk: old images pruned if it's filling up."},
	{"vps1-bridge", "vps1: the test server and the forum", "The community sign-in bridge's address lists still match each practice's psychologists and OpenWorks' support staff."},
	{"gh-alerts", "GitHub", "Security alerts: Dependabot, secret scanning, code scanning."},
	{"gh-settings", "GitHub", "deploy/github-settings.sh still reports the rulesets and the signing environment as set."},
	{"gh-access", "GitHub", "Who has access: collaborators, deploy keys, installed apps, Actions secrets and variables."},
	{"store-warnings", "The apps and the stores", "Play Console and App Store Connect: no policy warnings, no deadline coming."},
	{"store-testflight", "The apps and the stores", "A current TestFlight build for testers (they expire after 90 days)."},
	{"store-firebase", "The apps and the stores", "Firebase: one service-account key per practice server; retired servers' keys deleted."},
	{"store-apns", "The apps and the stores", "The Apple push key is still valid."},
	{"mail-dmarc", "Mail, DNS and domains", "DMARC reports: no mail failing SPF or DKIM."},
	{"mail-renewals", "Mail, DNS and domains", "Domain renewals coming up: steadyapp.co.za, openworks.co.za, each practice's own domain."},
	{"mail-caa", "Mail, DNS and domains", "The CAA records are still there."},
	{"own-backup", "OpenWorks' own computer", "deploy/backup-repo.sh has recent copies in ~/Backups/steady."},
	{"own-key", "OpenWorks' own computer", "The signing key has an offline backup, and its passphrase is stored safely."},
	{"paper-lawyer", "Paperwork", "\"Steady: for a lawyer to confirm\": anything new added, anything answered."},
	{"paper-subops", "Paperwork", "Sub-operators unchanged (if one changes, practices are told 30 days before)."},
	{"paper-privacy", "Paperwork", "The privacy policy still matches what Steady does; its date is current."},
	{"support-month", "Support", "What came in this month (tickets, emails, calls): a question asked twice is a fix for the app or the docs."},
}

func upkeepKnown(key string) bool {
	for _, u := range upkeepItems {
		if u.Key == key {
			return true
		}
	}
	return false
}

// ---- the file ----

// Todos reads todo.json; the first time, it starts from the list in web/todo-seed.json.
func (s *Store) Todos(now time.Time) (TodoFile, error) {
	s.todoMu.Lock()
	defer s.todoMu.Unlock()
	return s.loadTodos(now)
}

// UpdateTodos changes todo.json in one locked step.
func (s *Store) UpdateTodos(now time.Time, change func(*TodoFile) error) error {
	s.todoMu.Lock()
	defer s.todoMu.Unlock()
	f, err := s.loadTodos(now)
	if err != nil {
		return err
	}
	if err := change(&f); err != nil {
		return err
	}
	return writeJSON(s.path("todo.json"), f)
}

func (s *Store) loadTodos(now time.Time) (TodoFile, error) {
	var f TodoFile
	path := s.path("todo.json")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		f, err = seedTodos(now)
		if err != nil {
			return f, err
		}
		return f, writeJSON(path, f)
	}
	if err := readJSON(path, &f); err != nil {
		return f, fmt.Errorf("todo.json can't be read: %w", err)
	}
	if f.Upkeep == nil {
		f.Upkeep = map[string]map[string]Entry{}
	}
	for _, t := range f.Items {
		if t.ID >= f.Next {
			f.Next = t.ID + 1
		}
	}
	return f, nil
}

func seedTodos(now time.Time) (TodoFile, error) {
	f := TodoFile{Next: 1, Upkeep: map[string]map[string]Entry{}}
	b, err := webFS.ReadFile("web/todo-seed.json")
	if err != nil {
		return f, err
	}
	var seed []Todo
	if err := json.Unmarshal(b, &seed); err != nil {
		return f, fmt.Errorf("todo-seed.json: %w", err)
	}
	for _, t := range seed {
		if msg := t.check(); msg != "" {
			return f, fmt.Errorf("todo-seed.json, %q: %s", t.Title, msg)
		}
		t.ID = f.Next
		f.Next++
		t.Created = Entry{At: now, By: "fleet view", Text: "the first list"}
		t.Changed = now
		f.Items = append(f.Items, t)
	}
	return f, nil
}

func (f *TodoFile) find(id int) *Todo {
	for i := range f.Items {
		if f.Items[i].ID == id {
			return &f.Items[i]
		}
	}
	return nil
}

func (t *Todo) log(at time.Time, by, text string) {
	t.History = append(t.History, Entry{At: at, By: by, Text: text})
	if len(t.History) > maxHistory {
		t.History = t.History[len(t.History)-maxHistory:]
	}
	t.Changed = at
}

// ---- what people type ----

// oneLine: trimmed, every run of spaces or control characters one space; "" if too long.
func oneLine(v string, max int) (string, bool) {
	v = strings.ToValidUTF8(v, "")
	v = strings.Join(strings.FieldsFunc(v, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }), " ")
	return v, utf8.RuneCountInString(v) <= max
}

// lines: kept as typed, but without control characters other than line breaks and tabs, and
// at most two empty lines in a row.
func lines(v string, max int) (string, bool) {
	v = strings.ToValidUTF8(v, "")
	v = strings.ReplaceAll(strings.ReplaceAll(v, "\r\n", "\n"), "\r", "\n")
	v = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || !unicode.IsControl(r) {
			return r
		}
		return -1
	}, v)
	for strings.Contains(v, "\n\n\n\n") {
		v = strings.ReplaceAll(v, "\n\n\n\n", "\n\n\n")
	}
	v = strings.TrimSpace(v)
	return v, utf8.RuneCountInString(v) <= max
}

var dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

// check says what's wrong with an item, or "".
func (t *Todo) check() string {
	switch {
	case t.Title == "":
		return "Give it a title."
	case utf8.RuneCountInString(t.Title) > maxTitle:
		return fmt.Sprintf("The title is longer than %d characters.", maxTitle)
	case utf8.RuneCountInString(t.Detail) > maxDetail:
		return fmt.Sprintf("What needs to happen is longer than %d characters.", maxDetail)
	case t.Area == "" || utf8.RuneCountInString(t.Area) > 60:
		return "Choose where it belongs."
	case label(priorities, t.Priority) == "":
		return "Choose now, soon or later."
	case label(statuses, t.Status) == "":
		return "Choose a status."
	case utf8.RuneCountInString(t.Waiting) > 80:
		return "\"Waiting on\" is longer than 80 characters."
	}
	if t.Due != "" {
		if _, err := time.Parse("2006-01-02", t.Due); err != nil || !dateRe.MatchString(t.Due) {
			return "The date isn't a date."
		}
	}
	if t.Link != "" {
		u, err := url.Parse(t.Link)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || len(t.Link) > 500 {
			return "The link must be an https:// address."
		}
	}
	return ""
}

// fromForm fills an item's fields from the add or edit form.
func fromForm(get func(string) string, t *Todo) string {
	var ok [5]bool
	t.Title, ok[0] = oneLine(get("title"), maxTitle)
	t.Detail, ok[1] = lines(get("detail"), maxDetail)
	t.Area, ok[2] = oneLine(get("area"), 60)
	t.Waiting, ok[3] = oneLine(get("waiting"), 80)
	t.Link, ok[4] = oneLine(get("link"), 500)
	t.Priority = get("priority")
	t.Due = strings.TrimSpace(get("due"))
	if !ok[0] {
		return fmt.Sprintf("The title is longer than %d characters.", maxTitle)
	}
	if !ok[1] {
		return fmt.Sprintf("What needs to happen is longer than %d characters.", maxDetail)
	}
	return t.check()
}

// ---- what the pages show ----

type TodoRow struct {
	ID                                   int
	Title, Area, Waiting, Link           string
	Priority, PriorityLabel              string
	Status, StatusLabel                  string
	Due                                  string
	Overdue, Open                        bool
	Closed, ClosedNote, Changed, Created string
	Detail                               string
}

type TodoGroup struct {
	Key, Label string
	Rows       []TodoRow
}

type Chip struct {
	Label, Href string
	N           int
	On          bool
}

type TodoPage struct {
	Groups              []TodoGroup
	Closed              []TodoRow
	Open, Now, Look     int
	Waiting, Overdue    int
	Status, Area        string
	Chips, AreaChips    []Chip
	Areas               []string
	Priorities          []Choice
	UpkeepDone, UpkeepN int
	UpkeepMonth         string
	Fix, ToLook         int
	Empty               bool
}

func when(t, now time.Time) string {
	if t.IsZero() {
		return ""
	}
	l := t.In(sast)
	if l.Year() != now.In(sast).Year() {
		return l.Format("2 Jan 2006, 15:04")
	}
	return l.Format("2 Jan, 15:04")
}

func dueText(due string, now time.Time) (string, bool) {
	d, err := time.ParseInLocation("2006-01-02", due, sast)
	if err != nil {
		return "", false
	}
	today := now.In(sast)
	today = time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, sast)
	f := "Mon 2 Jan"
	if d.Year() != today.Year() {
		f = "2 Jan 2006"
	}
	return d.Format(f), d.Before(today)
}

func makeTodoRow(t Todo, now time.Time) TodoRow {
	r := TodoRow{ID: t.ID, Title: t.Title, Area: t.Area, Waiting: t.Waiting, Link: t.Link, Detail: t.Detail,
		Priority: t.Priority, PriorityLabel: label(priorities, t.Priority),
		Status: t.Status, StatusLabel: label(statuses, t.Status), Open: isOpen(t.Status),
		Changed: when(t.Changed, now), Created: when(t.Created.At, now) + " by " + t.Created.By}
	if t.Due != "" {
		r.Due, r.Overdue = dueText(t.Due, now)
		r.Overdue = r.Overdue && r.Open
	}
	if t.Closed != nil {
		r.Closed = t.Closed.By + ", " + when(t.Closed.At, now)
		r.ClosedNote = t.Closed.Text
	}
	return r
}

// sortRows: overdue first, then by date due (none last), then oldest first.
func sortRows(items []Todo) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if (a.Due == "") != (b.Due == "") {
			return a.Due != ""
		}
		if a.Due != b.Due {
			return a.Due < b.Due
		}
		return a.ID < b.ID
	})
}

func monthKey(t time.Time) string { return t.In(sast).Format("2006-01") }

func monthName(key string) string {
	t, err := time.Parse("2006-01", key)
	if err != nil {
		return key
	}
	return t.Format("January 2006")
}

func makeTodoPage(f TodoFile, status, area string, serverNames []string, now time.Time) TodoPage {
	p := TodoPage{Status: status, Area: area, Priorities: priorities, UpkeepN: len(upkeepItems),
		UpkeepMonth: monthName(monthKey(now))}
	byStatus := map[string]int{}
	inUse := map[string]int{}
	var openItems, closed []Todo
	for _, t := range f.Items {
		if isOpen(t.Status) {
			p.Open++
			byStatus[t.Status]++
			inUse[t.Area]++
			if t.Priority == "now" {
				p.Now++
			}
			if t.Due != "" {
				if _, late := dueText(t.Due, now); late {
					p.Overdue++
				}
			}
		}
		if area != "" && t.Area != area {
			continue
		}
		if isOpen(t.Status) {
			if status == "" || status == t.Status {
				openItems = append(openItems, t)
			}
		} else if status == "" || status == "done" {
			closed = append(closed, t)
		}
	}
	p.Look, p.Waiting = byStatus["look"], byStatus["waiting"]
	sortRows(openItems)
	for _, pr := range priorities {
		g := TodoGroup{Key: pr.Key, Label: pr.Label}
		for _, t := range openItems {
			if t.Priority == pr.Key {
				g.Rows = append(g.Rows, makeTodoRow(t, now))
			}
		}
		if len(g.Rows) > 0 {
			p.Groups = append(p.Groups, g)
		}
	}
	// done and not doing, newest first: the last 30 days, or all of them under "Done"
	sort.SliceStable(closed, func(i, j int) bool { return closed[i].Changed.After(closed[j].Changed) })
	for _, t := range closed {
		if status != "done" && now.Sub(t.Changed) > 30*24*time.Hour {
			continue
		}
		p.Closed = append(p.Closed, makeTodoRow(t, now))
	}
	p.Empty = len(p.Groups) == 0 && len(p.Closed) == 0

	q := func(st, ar string) string {
		v := url.Values{}
		if st != "" {
			v.Set("status", st)
		}
		if ar != "" {
			v.Set("area", ar)
		}
		if len(v) == 0 {
			return "/todo"
		}
		return "/todo?" + v.Encode()
	}
	p.Chips = []Chip{{"Everything open", q("", area), p.Open, status == ""}}
	for _, st := range statuses[:3] {
		p.Chips = append(p.Chips, Chip{st.Label, q(st.Key, area), byStatus[st.Key], status == st.Key})
	}
	p.Chips = append(p.Chips, Chip{"Done", q("done", area), -1, status == "done"})
	if len(inUse) > 1 || area != "" {
		p.AreaChips = []Chip{{"All areas", q(status, ""), -1, area == ""}}
		names := make([]string, 0, len(inUse))
		for a := range inUse {
			names = append(names, a)
		}
		sort.Strings(names)
		for _, a := range names {
			p.AreaChips = append(p.AreaChips, Chip{a, q(status, a), inUse[a], area == a})
		}
	}
	p.Areas = append(append([]string{}, areas...), serverNames...)
	for _, u := range upkeepItems {
		if _, ok := f.Upkeep[monthKey(now)][u.Key]; ok {
			p.UpkeepDone++
		}
	}
	return p
}

type UpkeepLine struct {
	Key, Text, By string
}

type UpkeepSection struct {
	Name  string
	Lines []UpkeepLine
}

type UpkeepPage struct {
	Month, MonthName   string
	Prev, Next         string
	PrevName, NextName string
	Done, N            int
	DoneW              float64
	Sections           []UpkeepSection
	Current            bool
}

func makeUpkeepPage(f TodoFile, month string, now time.Time) UpkeepPage {
	p := UpkeepPage{Month: month, MonthName: monthName(month), N: len(upkeepItems), Current: month == monthKey(now)}
	t, _ := time.Parse("2006-01", month)
	if prev := t.AddDate(0, -1, 0); prev.Year() >= 2026 {
		p.Prev, p.PrevName = prev.Format("2006-01"), monthName(prev.Format("2006-01"))
	}
	if !p.Current {
		p.Next = t.AddDate(0, 1, 0).Format("2006-01")
		p.NextName = monthName(p.Next)
	}
	got := f.Upkeep[month]
	for _, u := range upkeepItems {
		if len(p.Sections) == 0 || p.Sections[len(p.Sections)-1].Name != u.Section {
			p.Sections = append(p.Sections, UpkeepSection{Name: u.Section})
		}
		l := UpkeepLine{Key: u.Key, Text: u.Text}
		if c, ok := got[u.Key]; ok {
			l.By = c.By + ", " + when(c.At, now)
			p.Done++
		}
		s := &p.Sections[len(p.Sections)-1]
		s.Lines = append(s.Lines, l)
	}
	p.DoneW = float64(p.Done) * 100 / float64(p.N)
	return p
}

// upkeepMonth: a month that can be shown or changed: from the first in 2026 to this one.
func upkeepMonth(v string, now time.Time) (string, bool) {
	if v == "" {
		return monthKey(now), true
	}
	t, err := time.Parse("2006-01", v)
	if err != nil || t.Year() < 2026 || v > monthKey(now) {
		return "", false
	}
	return t.Format("2006-01"), true
}
