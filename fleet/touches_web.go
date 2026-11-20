// The tripwire touch pages: one touch looked into (/frontdoor/touch/{id}), and every touch kept
// (/frontdoor/touches). A touch is marked as a test, a scanner or real and dealt with, or given a
// note; each change is in the touch's notes and the audit log, with who made it.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Hint is one thing the page can say about a touch: bad, warn or muted.
type Hint struct{ Class, Text string }

type fact struct{ Name, Value string }

type link struct{ Name, URL string }

// TouchRow is a touch in a list.
type TouchRow struct {
	ID, When, Server, Label, Type, Request, IP, Verdict, Class string
	Open, This                                                 bool
}

type TrailRow struct {
	When, Method, Path, Agent, Referer string
	Status                             int
	Touch                              bool
}

type TrailView struct {
	Kept     string // when it's a copy kept with a mark, when that was
	Summary  []string
	Rows     []TrailRow
	SameTool string // the touch's own User-Agent, shown once instead of on every row
}

func touchRow(t Touch, this bool, now time.Time) TouchRow {
	req := t.Method + " " + t.Path
	if t.Query != "" {
		req += "?" + t.Query
	}
	return TouchRow{ID: t.ID, When: when(t.At, now), Server: t.Server, Label: t.Label, Type: t.Type, Request: clip(req, 140), IP: t.IP,
		Verdict: t.VerdictLabel(), Class: t.VerdictClass(), Open: t.Open(), This: this}
}

func statusWords(code int) string {
	switch {
	case code == 0:
		return "not known"
	case code == 404:
		return "404, not found: as for anything else that isn't there"
	case code == 400:
		return "400, refused: as for any wrong sign-in"
	case code == 401 || code == 403:
		return fmt.Sprintf("%d, refused", code)
	case code == 429:
		return "429, asked too often"
	case code >= 200 && code < 300:
		return fmt.Sprintf("%d, answered", code)
	case code >= 300 && code < 400:
		return fmt.Sprintf("%d, sent elsewhere", code)
	}
	return strconv.Itoa(code)
}

var typeWords = map[string]string{"path": "a path listed only in robots.txt", "value": "a planted secret", "name": "a sign-in name nobody has"}

// touchFacts: what happened, as plainly as the server kept it.
func touchFacts(t Touch, now time.Time) []fact {
	f := []fact{
		{"When", t.At.In(sast).Format("Mon 2 Jan 2006, 15:04:05") + " SAST (" + ago(t.At, now) + ")"},
		{"Server", t.Server},
		{"Decoy", t.Label + " (" + typeWords[t.Type] + ")"},
	}
	if t.Where != "" {
		f = append(f, fact{"Found in", t.Where})
	}
	req := t.Method + " " + t.Path
	if t.Query != "" {
		req += "?" + t.Query
	}
	f = append(f, fact{"Request", req}, fact{"Answered", statusWords(t.Status)})
	if t.Host != "" {
		f = append(f, fact{"Asked for", t.Host})
	}
	f = append(f, fact{"From", t.IP})
	if t.Forwarded != "" && t.Forwarded != t.IP {
		f = append(f, fact{"Forwarded as", t.Forwarded})
	}
	agent := t.Agent
	if agent == "" {
		agent = "(nothing)"
	}
	f = append(f, fact{"Said it was", agent})
	if t.Headers != "" {
		f = append(f, fact{"Headers sent", t.Headers})
	}
	if t.Lang != "" {
		f = append(f, fact{"Language", t.Lang})
	}
	if t.Referer != "" {
		f = append(f, fact{"Came from", t.Referer})
	}
	account := t.Account
	if account == "" {
		account = "none"
	}
	f = append(f, fact{"Signed in", account}, fact{"First seen here", when(t.Seen, now)})
	return f
}

// fleetSignIns: when an address signed in to the fleet view, from the audit log's tail.
func (a *App) fleetSignIns(ip string) []string {
	var out []string
	for _, l := range a.store.RecentAudit(3000) {
		if l["ip"] == ip && l["what"] == "signed in" {
			at, _ := time.Parse(time.RFC3339, l["at"])
			out = append(out, l["who"]+" on "+when(at, a.now()))
			if len(out) == 3 {
				break
			}
		}
	}
	return out
}

// touchHints: what the touch suggests, the most telling first.
func (a *App) touchHints(t Touch, youIP string, others []Touch, tr *Trail, o Origin) []Hint {
	var h []Hint
	if t.IP != "" && t.IP == youIP {
		h = append(h, Hint{"muted", "That's the address you're using now: most likely one of us testing."})
	}
	if ins := a.fleetSignIns(t.IP); len(ins) > 0 {
		h = append(h, Hint{"muted", "This address signed in to the fleet view (" + strings.Join(ins, "; ") + "): most likely one of us."})
	}
	if t.Account != "" {
		if strings.HasPrefix(t.Account, "a patient") {
			h = append(h, Hint{"bad", "It came signed in, with a patient's account: that sign-in may be in someone else's hands. The server's own log says which account (docker compose logs pocketbase | grep tripwire); tell the practice."})
		} else {
			h = append(h, Hint{"bad", "It came signed in, with " + t.Account + ": that account's sign-in may be in someone else's hands. Reset it and ask its owner."})
		}
	}
	switch t.Type {
	case "value":
		h = append(h, Hint{"bad", "It used a planted secret (" + t.Label + "): whoever did this has read where it was planted, as scanners can't guess one. Unless it was a test, take it that someone who shouldn't have has read that place."})
	case "name":
		h = append(h, Hint{"bad", "It tried to sign in as a name nobody has, which exists only where it was planted (" + t.Label + "). Unless it was a test, someone has read that place."})
	case "path":
		txt := "It asked for a path listed only in robots.txt, which people never read and scanners do. Scanners do this every day; a person doing it is looking for a way in."
		if tr != nil {
			for _, r := range tr.Requests {
				at := parseTime(r.At)
				if strings.HasPrefix(r.Path, "/robots.txt") && !at.IsZero() && !at.After(t.At) && t.At.Sub(at) < 24*time.Hour {
					txt += fmt.Sprintf(" It read /robots.txt %s before.", roughly(t.At.Sub(at)))
					break
				}
			}
		}
		h = append(h, Hint{"warn", txt})
	}
	if extra := claimed(t); extra != "" {
		h = append(h, Hint{"warn", "It claimed to be forwarded for " + extra + ": a trick to look like it comes from inside, or from someone else. The address above is the one that really connected."})
	}
	if ip := net.ParseIP(strings.Trim(hostOnly(t.Host), "[]")); ip != nil {
		h = append(h, Hint{"muted", "It asked for the server by its address (" + t.Host + "), not its name: typical of scanning that goes through every address on the internet."})
	}
	h = append(h, Hint{"muted", "What it said it was: " + toolOf(t.Agent) + "."})
	if o.Private != "" {
		h = append(h, Hint{"warn", "Its address is " + o.Private + "."})
	} else if o.Network != "" && looksHosting(o.Network) {
		h = append(h, Hint{"muted", "Its network (" + o.Network + ") looks like a hosting or cloud company: a rented server, not someone's home or office."})
	}
	servers := map[string]bool{}
	for _, x := range others {
		if x.URL != t.URL {
			servers[x.Server] = true
		}
	}
	if len(servers) > 0 {
		var names []string
		for n := range servers {
			names = append(names, n)
		}
		sort.Strings(names)
		h = append(h, Hint{"warn", "The same address touched a tripwire on " + strings.Join(names, ", ") + " too."})
	}
	return h
}

func roughly(d time.Duration) string {
	switch {
	case d < 2*time.Second:
		return "a moment"
	case d < time.Minute:
		return fmt.Sprintf("%d seconds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d minutes", int(d.Minutes()))
	}
	return fmt.Sprintf("%d hours", int(d.Hours()))
}

func hostOnly(h string) string {
	if host, _, err := net.SplitHostPort(h); err == nil {
		return host
	}
	return h
}

// claimed: the addresses a request said it was forwarded for, other than its own.
func claimed(t Touch) string {
	var out []string
	for _, f := range strings.Split(t.Forwarded, ",") {
		if f = strings.TrimSpace(f); f != "" && f != t.IP {
			out = append(out, f)
		}
	}
	return strings.Join(out, ", ")
}

func originLinks(ip string) []link {
	q := url.PathEscape(ip)
	return []link{
		{"GreyNoise (is it a known mass scanner?)", "https://viz.greynoise.io/ip/" + q},
		{"AbuseIPDB (reported for abuse?)", "https://www.abuseipdb.com/check/" + q},
		{"Shodan (what it runs)", "https://www.shodan.io/host/" + q},
		{"ipinfo (who has the address)", "https://ipinfo.io/" + q},
	}
}

// trailView: a trail as the page shows it, the touches in it picked out.
func trailView(tr *Trail, touches []Touch, agent string, now time.Time) *TrailView {
	v := &TrailView{SameTool: agent}
	days := "the server keeps its request log " + strconv.Itoa(tr.Logs.Days) + " days"
	if !tr.Logs.IP {
		v.Summary = append(v.Summary, "The server's request log doesn't keep addresses, so there's no trail (PocketBase's log settings).")
		return v
	}
	if tr.Total == 0 {
		v.Summary = append(v.Summary, "Nothing from this address in the server's request log ("+days+").")
		return v
	}
	first, last := parseTime(tr.First), parseTime(tr.Last)
	v.Summary = append(v.Summary, fmt.Sprintf("%d request(s) from this address, %s to %s (%s).", tr.Total, when(first, now), when(last, now), days))
	for _, s := range tr.SignedIn {
		v.Summary = append(v.Summary, fmt.Sprintf("%d of them made with %s, %s to %s: only counted, never what an account does.", s.N, s.As, when(parseTime(s.First), now), when(parseTime(s.Last), now)))
	}
	if tr.More > 0 {
		v.Summary = append(v.Summary, fmt.Sprintf("%d older one(s) without an account aren't shown.", tr.More))
	}
	for _, r := range tr.Requests {
		at := parseTime(r.At)
		row := TrailRow{When: at.In(sast).Format("2 Jan 15:04:05"), Method: r.Method, Path: r.Path, Status: r.Status, Agent: r.Agent, Referer: r.Referer}
		if r.Agent == agent {
			row.Agent = ""
		}
		for _, t := range touches {
			if d := at.Sub(t.At); d > -3*time.Second && d < 3*time.Second && strings.HasPrefix(r.Path, t.Path) {
				row.Touch = true
			}
		}
		v.Rows = append(v.Rows, row)
	}
	return v
}

func (a *App) serverByURL(u string) (Server, int, bool) {
	servers, _ := a.store.Servers()
	for i, sv := range servers {
		if strings.TrimRight(sv.URL, "/") == strings.TrimRight(u, "/") {
			return sv, i, true
		}
	}
	return Server{}, 0, false
}

func findTouch(list []Touch, id string) (Touch, bool) {
	for _, t := range list {
		if t.ID == id {
			return t, true
		}
	}
	return Touch{}, false
}

// fromAddress: the other touches from the same address, on any server, newest first.
func fromAddress(list []Touch, t Touch) []Touch {
	var out []Touch
	for _, x := range list {
		if x.ID != t.ID && x.IP != "" && x.IP == t.IP {
			out = append(out, x)
		}
	}
	return out
}

func (a *App) touchPage(w http.ResponseWriter, r *http.Request, s *Session) {
	id := r.PathValue("id")
	list, err := a.store.Touches()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	t, ok := findTouch(list, id)
	if !validTouchID(id) || !ok {
		http.NotFound(w, r)
		return
	}
	now := a.now()
	others := fromAddress(list, t)
	var rows []TouchRow
	openOthers := 0
	for _, x := range others {
		rows = append(rows, touchRow(x, false, now))
		if x.Open() {
			openOthers++
		}
	}
	// where it came from (DNS), and what it did on that server (the server's request log)
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	origin := a.origins.get(ctx, t.IP, a.lookup)
	var trail *TrailView
	var live *Trail
	trailErr := ""
	sameServer := []Touch{t}
	for _, x := range others {
		if x.URL == t.URL {
			sameServer = append(sameServer, x)
		}
	}
	if sv, _, ok := a.serverByURL(t.URL); ok {
		live, err = a.poller.Trail(ctx, sv, t.IP)
		if err != nil {
			trailErr = err.Error()
		}
	} else {
		trailErr = "that server isn't in servers.json any more"
	}
	if live != nil {
		trail = trailView(live, sameServer, t.Agent, now)
	} else {
		for _, x := range sameServer {
			if x.Trail != nil {
				trail = trailView(x.Trail, sameServer, t.Agent, now)
				trail.Kept = when(x.Trail.At, now)
				break
			}
		}
	}
	var notes []histLine
	for i := len(t.Notes) - 1; i >= 0; i-- {
		notes = append(notes, histLine{when(t.Notes[i].At, now), t.Notes[i].By, t.Notes[i].Text})
	}
	_, n, known := a.serverByURL(t.URL)
	var links []link
	if origin.Private == "" && origin.Err != "not an address" {
		links = originLinks(t.IP)
	}
	a.render(w, "touch.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "T": t, "Facts": touchFacts(t, now), "Notes": notes,
		"Hints": a.touchHints(t, a.clientIP(r), others, live, origin), "Origin": origin, "Links": links, "Others": rows, "OpenOthers": openOthers,
		"Trail": trail, "TrailErr": trailErr, "Verdicts": verdicts, "ServerLink": map[bool]string{true: "/s/" + strconv.Itoa(n)}[known],
		"Msg": a.sessions.TakeFlash(s)})
}

// touchMark: a mark (test, scanner, dealt), a note, or reopening; with "also", the other open
// touches from the same address get the same mark.
func (a *App) touchMark(w http.ResponseWriter, r *http.Request, s *Session) {
	id := r.PathValue("id")
	if !validTouchID(id) {
		http.NotFound(w, r)
		return
	}
	now := a.now()
	op := r.PostFormValue("op")
	note, ok := lines(r.PostFormValue("note"), 1000)
	back := "/frontdoor/touch/" + id
	v, isVerdict := verdictOf(op)
	switch {
	case !ok:
		a.sessions.SetFlash(s, "Not saved: the note is longer than 1000 characters.")
		http.Redirect(w, r, back, http.StatusSeeOther)
		return
	case !isVerdict && op != "note" && op != "reopen":
		a.sessions.SetFlash(s, "That form wasn't one of this page's.")
		http.Redirect(w, r, back, http.StatusSeeOther)
		return
	case op == "note" && note == "":
		a.sessions.SetFlash(s, "Nothing saved: write the note first.")
		http.Redirect(w, r, back, http.StatusSeeOther)
		return
	case op == "dealt" && note == "":
		a.sessions.SetFlash(s, "Not saved: say what was done about it (it stays with the touch).")
		http.Redirect(w, r, back, http.StatusSeeOther)
		return
	}
	text := map[string]string{"note": "Note", "reopen": "Reopened"}[op]
	if isVerdict {
		text = "Marked " + v.Label
	}
	if note != "" {
		text += ": " + note
	}
	// with "real: dealt with", the trail as it is now is kept with the touch (the server keeps
	// its request log only a few days)
	var kept *Trail
	list, err := a.store.Touches()
	t, found := findTouch(list, id)
	if err == nil && found && op == "dealt" {
		if sv, _, ok := a.serverByURL(t.URL); ok {
			ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
			kept, _ = a.poller.Trail(ctx, sv, t.IP)
			cancel()
		}
	}
	also := 0
	err = a.store.UpdateTouches(now, func(list []Touch) ([]Touch, error) {
		var this *Touch
		for i := range list {
			if list[i].ID == id {
				this = &list[i]
			}
		}
		if this == nil {
			found = false
			return list, nil
		}
		apply := func(x *Touch, text string) {
			switch {
			case isVerdict:
				x.Verdict = v.Key
			case op == "reopen":
				x.Verdict = ""
			}
			x.Notes = append(x.Notes, Entry{At: now, By: s.User, Text: text})
		}
		apply(this, text)
		if kept != nil {
			this.Trail = kept
		}
		if r.PostFormValue("also") == "1" && isVerdict {
			for i := range list {
				x := &list[i]
				if x.ID != id && x.IP != "" && x.IP == this.IP && x.Open() {
					apply(x, text+" (with the touch of "+when(this.At, now)+" on "+this.Server+")")
					also++
				}
			}
		}
		return list, nil
	})
	switch {
	case err != nil:
		a.sessions.SetFlash(s, "Not saved: touches.json can't be written.")
	case !found:
		http.NotFound(w, r)
		return
	default:
		detail := fmt.Sprintf("%s: %s at %s from %s: %s", t.Server, t.Label, t.At.UTC().Format(time.RFC3339), t.IP, text)
		if also > 0 {
			detail += fmt.Sprintf(" (and %d more from that address)", also)
		}
		a.store.Audit(s.User, a.clientIP(r), "tripwire touch", detail)
		msg := "Saved."
		if isVerdict || op == "reopen" {
			msg = strings.ToUpper(text[:1]) + strings.SplitN(text, ":", 2)[0][1:] + "."
			if also > 0 {
				msg = fmt.Sprintf("%s So are the other %d from this address.", msg, also)
			}
		}
		a.sessions.SetFlash(s, msg)
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}

// touchesPage: every touch kept (90 days; a year for real ones), those not looked at first.
func (a *App) touchesPage(w http.ResponseWriter, r *http.Request, s *Session) {
	list, err := a.store.Touches()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	now := a.now()
	show := r.URL.Query().Get("show")
	var rows []TouchRow
	open := 0
	for _, t := range list {
		if t.Open() {
			open++
		}
		if show == "all" || t.Open() {
			rows = append(rows, touchRow(t, false, now))
		}
	}
	a.render(w, "touches.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Rows": rows, "Open": open, "All": len(list), "ShowAll": show == "all"})
}
