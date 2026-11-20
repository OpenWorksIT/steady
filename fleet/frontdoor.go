// The Front door: what every service turned away, and the tripwires touched. Practice servers
// count their own (server/pb_hooks/lib/frontdoor.js, in their status); OpenWorks' own services
// on vps1 are counted from the Caddy in front of them (edge-frontdoor.py, every 10 minutes).
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// DoorCounts: a stretch of time, by kind. A practice server counts probes, the closed door,
// failed sign-ins, rate limits, refusals and an account's own refusals; vps1's services what
// Caddy saw (requests, refused, not found, rate limits, errors).
type DoorCounts struct {
	Probe, Closed, Signin, Limited, Refused, Insider, Trip int
	Requests, Missing, Errors                              int
	Sources                                                int
}

type DoorPath struct {
	Kind, Path string
	N          int
}

type DoorTrip struct {
	ID, When, Label, Type, Where, Path, Method, IP, Agent string
	Status                                                int
	Open                                                  bool   // not yet marked
	Verdict, Class                                        string // what was made of it, in words
}

// DoorService is one service's row and section on the Front door page.
type DoorService struct {
	Name, Host, Link string
	Practice         bool // a practice server (its own count) rather than one of vps1's services
	Have             bool
	Err              string
	Day, Week        DoorCounts
	Paths, Agents    []DoorPath
	Trips            []DoorTrip
	Open, Closed     int      // touches listed this week: not looked at yet, and marked
	Unlisted         int      // touches counted this week that the server didn't keep or list
	Level            string   // good, warn, bad
	Flags            []string // why it isn't good
	Tripwires        string   // how many decoys are set, for a practice server
	Problems         []string // decoys the server ignores, and why
}

func intOf(m map[string]any, k string) int {
	f, _ := num(m[k])
	return int(f)
}

func doorCounts(m map[string]any) DoorCounts {
	if m == nil {
		return DoorCounts{}
	}
	return DoorCounts{
		Probe: intOf(m, "probe"), Closed: intOf(m, "closed"), Signin: intOf(m, "signin"), Limited: intOf(m, "limited"),
		Refused: intOf(m, "refused"), Insider: intOf(m, "insider"), Trip: intOf(m, "trip"),
		Requests: intOf(m, "requests"), Missing: intOf(m, "missing"), Errors: intOf(m, "errors"), Sources: intOf(m, "sources"),
	}
}

var kindWords = map[string]string{"probe": "probe", "closed": "closed door", "signin": "failed sign-in", "limited": "rate-limited",
	"refused": "refused", "insider": "an account's own"}

func doorPaths(v any, kindKey string) []DoorPath {
	list, _ := v.([]any)
	var out []DoorPath
	for _, x := range list {
		m, _ := x.(map[string]any)
		if m == nil {
			continue
		}
		p := DoorPath{Path: clip(str(m["path"]), 120), N: intOf(m, "n")}
		if kindKey == "status" {
			p.Kind = fmt.Sprintf("%d", intOf(m, "status"))
		} else if k := kindWords[str(m["kind"])]; k != "" {
			p.Kind = k
		} else {
			p.Kind = clip(str(m["kind"]), 20)
		}
		if p.Path == "" {
			p.Path = clip(str(m["agent"]), 120)
		}
		out = append(out, p)
	}
	return out
}

// jump: a kind's last 24 hours against the 6 days before (each kind has a floor, so a quiet
// server going from 1 to 4 isn't news). Returns the note, or "".
func jump(name string, day, week, floor int, what string) string {
	before := float64(week-day) / 6
	if day < floor || float64(day) < 3*before {
		return ""
	}
	if before < 1 {
		return fmt.Sprintf("%s: %d in 24 h (hardly any the week before): %s", name, day, what)
	}
	return fmt.Sprintf("%s: %d in 24 h (about %.0f a day before): %s", name, day, before, what)
}

// practiceDoor: one practice server's front door. marks: what was made of each touch (by id;
// nil: every touch still open).
func practiceDoor(i int, st *Status, now time.Time, marks map[string]Mark) DoorService {
	row := makeRow(i, st, now)
	s := DoorService{Name: row.Name, Host: row.Domain, Link: fmt.Sprintf("/s/%d", i), Practice: true, Level: "good"}
	if row.Err != "" {
		s.Err, s.Level = row.Err, "warn"
		return s
	}
	fd, _ := st.Data["frontDoor"].(map[string]any)
	if fd == nil {
		s.Err = "no front door from this server yet (it comes with Steady 1.2.7)"
		return s
	}
	s.Have = true
	s.Day = doorCounts(asMap(fd["last24h"]))
	s.Week = doorCounts(asMap(fd["last7d"]))
	s.Paths = doorPaths(fd["paths"], "kind")
	s.Agents = doorPaths(fd["agents"], "")
	if list, ok := fd["trips"].([]any); ok {
		for _, x := range list {
			m := asMap(x)
			if m == nil {
				continue
			}
			t, ok := touchFrom(st.Server, m, now)
			if !ok {
				continue
			}
			d := DoorTrip{ID: t.ID, When: t.At.In(sast).Format("2 Jan 15:04") + " (" + ago(t.At, now) + ")", Label: t.Label, Type: t.Type,
				Where: t.Where, Path: t.Path, Method: t.Method, IP: t.IP, Agent: clip(t.Agent, 120), Status: t.Status, Open: true,
				Verdict: "not looked at yet", Class: "bad"}
			if mk, ok := marks[t.ID]; ok {
				t.Verdict, t.Notes = mk.Verdict, make([]Entry, mk.Notes)
				d.Open, d.Verdict, d.Class = t.Open(), t.VerdictLabel(), t.VerdictClass()
				if mk.By != "" && !d.Open {
					d.Verdict += " (" + mk.By + ")"
				}
			}
			if d.Open {
				s.Open++
			} else {
				s.Closed++
			}
			s.Trips = append(s.Trips, d)
		}
	}
	if s.Unlisted = s.Week.Trip - s.Open - s.Closed; s.Unlisted < 0 {
		s.Unlisted = 0
	}
	if s.Open > 0 {
		s.Level = "bad"
		s.Flags = append(s.Flags, fmt.Sprintf("a tripwire was touched %d time(s) this week, not looked at yet: whoever did it was looking for a way in, or has something they shouldn't (see below)", s.Open))
	}
	for _, j := range []struct {
		name         string
		day, week, f int
		what         string
	}{
		{"failed sign-ins", s.Day.Signin, s.Week.Signin, 30, "someone may be guessing passwords (each address rests after 10 wrong tries)"},
		{"tries at the closed dashboard", s.Day.Closed, s.Week.Closed, 20, "someone is after PocketBase's superuser sign-in"},
		{"an account's own refusals", s.Day.Insider, s.Week.Insider, 20, "a signed-in account is asking for what isn't its own"},
		{"probes", s.Day.Probe, s.Week.Probe, 300, "more scanning than usual"},
		{"rate limits", s.Day.Limited, s.Week.Limited, 50, "something is asking too often"},
		{"refusals", s.Day.Refused, s.Week.Refused, 200, "more unauthorised requests than usual"},
	} {
		if n := jump(j.name, j.day, j.week, j.f, j.what); n != "" {
			s.Flags = append(s.Flags, n)
			if s.Level == "good" {
				s.Level = "warn"
			}
		}
	}
	if tw := asMap(st.Data["tripwires"]); tw != nil {
		n := intOf(tw, "paths") + intOf(tw, "values") + intOf(tw, "names")
		switch {
		case n == 0:
			s.Tripwires = "no tripwires set (./decoys.sh on the server)"
		case tw["alertEmail"] == true:
			s.Tripwires = fmt.Sprintf("%d tripwire(s) set, emailed when touched", n)
		default:
			s.Tripwires = fmt.Sprintf("%d tripwire(s) set, not emailed (STEADY_ALERT_EMAIL and email set up)", n)
		}
		if ps, ok := tw["problems"].([]any); ok {
			for _, p := range ps {
				s.Problems = append(s.Problems, clip(str(p), 160))
			}
		}
		if len(s.Problems) > 0 && s.Level == "good" {
			s.Level = "warn"
		}
	}
	return s
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// EdgeDoor is edge-frontdoor.py's summary of vps1's own services.
type EdgeDoor struct {
	At    time.Time
	Hosts map[string]map[string]any
	Err   string
}

// EdgeFrontDoor reads edge-frontdoor.py's summary; Err says why there's none.
func (s *Store) EdgeFrontDoor() EdgeDoor {
	b, err := os.ReadFile(s.path("edge-frontdoor.json"))
	if err != nil {
		return EdgeDoor{Err: "not counted yet: install edge-frontdoor.timer on vps1 (docs/FRONTDOOR.md)"}
	}
	var raw struct {
		At    string                    `json:"at"`
		Hosts map[string]map[string]any `json:"hosts"`
	}
	if json.Unmarshal(b, &raw) != nil {
		return EdgeDoor{Err: "edge-frontdoor.json can't be read"}
	}
	at, _ := time.Parse(time.RFC3339, raw.At)
	return EdgeDoor{At: at, Hosts: raw.Hosts}
}

func hostOf(u string) string {
	u = strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://")
	if i := strings.IndexAny(u, "/:"); i >= 0 {
		u = u[:i]
	}
	return strings.ToLower(u)
}

// edgeDoors: vps1's services, named where the fleet view knows them (the forum and its sign-in
// bridge, from community.json); a practice server's own site is left out (it counts itself).
func edgeDoors(ed EdgeDoor, cfg *Community, practice map[string]bool, now time.Time) []DoorService {
	names := map[string]string{}
	if cfg != nil {
		names[hostOf(cfg.URL)] = "Community forum"
		if cfg.Signin != "" {
			names[hostOf(cfg.Signin)] = "Sign-in bridge"
		}
	}
	var hosts []string
	for h := range ed.Hosts {
		if !practice[h] {
			hosts = append(hosts, h)
		}
	}
	sort.Slice(hosts, func(i, j int) bool {
		ni, nj := names[hosts[i]] != "", names[hosts[j]] != ""
		if ni != nj {
			return ni
		}
		return hosts[i] < hosts[j]
	})
	stale := !ed.At.IsZero() && now.Sub(ed.At) > 40*time.Minute
	var out []DoorService
	for _, h := range hosts {
		m := ed.Hosts[h]
		name := names[h]
		if name == "" && strings.HasPrefix(h, "fleet.") {
			name = "Fleet view"
		}
		if name == "" {
			name = h
		}
		s := DoorService{Name: name, Host: h, Have: true, Level: "good",
			Day: doorCounts(asMap(m["last24h"])), Week: doorCounts(asMap(m["last7d"])),
			Paths: doorPaths(m["paths"], "status"), Agents: doorPaths(m["agents"], "")}
		if stale {
			s.Err = "counted " + ago(ed.At, now) + ": is edge-frontdoor.timer running on vps1? (sudo systemctl status edge-frontdoor.timer)"
			s.Level = "warn"
		}
		for _, j := range []struct {
			name         string
			day, week, f int
			what         string
		}{
			{"refusals", s.Day.Refused, s.Week.Refused, 100, "more unauthorised requests than usual"},
			{"not found", s.Day.Missing, s.Week.Missing, 300, "more scanning than usual"},
			{"rate limits", s.Day.Limited, s.Week.Limited, 50, "something is asking too often"},
			{"errors", s.Day.Errors, s.Week.Errors, 50, "the service is answering with errors"},
		} {
			if n := jump(j.name, j.day, j.week, j.f, j.what); n != "" {
				s.Flags = append(s.Flags, n)
				s.Level = "warn"
			}
		}
		out = append(out, s)
	}
	return out
}

// FrontDoorPage: every service, practice servers first.
type FrontDoorPage struct {
	Services []DoorService
	EdgeErr  string
	Trips    int // tripwire touches this week not looked at yet, across the practice servers
	Marked   int // and the ones marked
}

func makeFrontDoor(sts []*Status, ed EdgeDoor, cfg *Community, marks map[string]Mark, now time.Time) FrontDoorPage {
	var p FrontDoorPage
	for i, st := range sts {
		s := practiceDoor(i, st, now, marks)
		p.Trips += s.Open
		p.Marked += s.Closed
		p.Services = append(p.Services, s)
	}
	p.EdgeErr = ed.Err
	p.Services = append(p.Services, edgeDoors(ed, cfg, practiceHosts(sts), now)...)
	return p
}

// practiceHosts: the practice servers' own sites (they count their own front door).
func practiceHosts(sts []*Status) map[string]bool {
	out := map[string]bool{}
	for _, st := range sts {
		out[hostOf(st.Server.URL)] = true
	}
	return out
}

// doorChecks: the Front door's findings for Checks. A touched tripwire is something to fix, a
// jump or an ignored decoy something to look at.
func doorChecks(svc DoorService) (fix, look []string) {
	for _, f := range svc.Flags {
		if strings.HasPrefix(f, "a tripwire was touched") {
			fix = append(fix, f)
		} else {
			look = append(look, f)
		}
	}
	for _, p := range svc.Problems {
		look = append(look, "a decoy is ignored: "+p)
	}
	return fix, look
}
