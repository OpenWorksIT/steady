// Tripwire touches, as the fleet view keeps them (touches.json in its data folder): every touch
// a practice server lists is copied here when the server is polled, so a server that is broken
// into can't take its record back, and a touch can be looked into after the server has let it go
// (it lists 7 days). With each, what OpenWorks made of it: a test, a scanner, or real and dealt
// with, and every note, with who and when (also in audit.log).
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	touchKeep     = 90 * 24 * time.Hour  // a touch is kept this long
	touchKeepReal = 366 * 24 * time.Hour // one marked real and dealt with, a year
	maxTouches    = 5000
)

// Touch is one tripwire touch, as a practice server reported it, and what was made of it.
type Touch struct {
	ID        string    `json:"id"`
	Server    string    `json:"server"` // its name in servers.json when it was seen
	URL       string    `json:"url"`
	At        time.Time `json:"at"`
	Label     string    `json:"label"`
	Type      string    `json:"type"` // path, value, name
	Where     string    `json:"where,omitempty"`
	Method    string    `json:"method,omitempty"`
	Path      string    `json:"path,omitempty"`
	Query     string    `json:"query,omitempty"`
	Host      string    `json:"host,omitempty"`
	IP        string    `json:"ip,omitempty"`
	Agent     string    `json:"agent,omitempty"`
	Referer   string    `json:"referer,omitempty"`
	Lang      string    `json:"lang,omitempty"`
	Forwarded string    `json:"forwarded,omitempty"`
	Headers   string    `json:"headers,omitempty"`
	Account   string    `json:"account,omitempty"`
	Status    int       `json:"status,omitempty"`
	Seen      time.Time `json:"seen"`
	Verdict   string    `json:"verdict,omitempty"` // "" (open), test, scanner, dealt
	Notes     []Entry   `json:"notes,omitempty"`   // every mark and note
	Trail     *Trail    `json:"trail,omitempty"`   // kept with "real: dealt with"
}

// Open: not yet marked as a test, a scanner or dealt with.
func (t Touch) Open() bool { return t.Verdict == "" }

type verdict struct{ Key, Label, Button, Class string }

var verdicts = []verdict{
	{"test", "a test by us", "Mark as a test", "muted"},
	{"scanner", "a scanner, nothing more", "A scanner, nothing more", "muted"},
	{"dealt", "real: dealt with", "Real: dealt with", "warn"},
}

func verdictOf(key string) (verdict, bool) {
	for _, v := range verdicts {
		if v.Key == key {
			return v, true
		}
	}
	return verdict{}, false
}

// VerdictLabel: what was made of it, in words.
func (t Touch) VerdictLabel() string {
	if v, ok := verdictOf(t.Verdict); ok {
		return v.Label
	}
	if len(t.Notes) > 0 {
		return "being looked into"
	}
	return "not looked at yet"
}

func (t Touch) VerdictClass() string {
	if v, ok := verdictOf(t.Verdict); ok {
		return v.Class
	}
	return "bad"
}

// touchID: the same touch gets the same id every time the server lists it.
func touchID(serverURL, at, label, typ, path, ip string) string {
	h := sha256.Sum256([]byte(strings.Join([]string{strings.TrimRight(serverURL, "/"), at, label, typ, path, ip}, "\x00")))
	return hex.EncodeToString(h[:8])
}

func validTouchID(id string) bool {
	if len(id) != 16 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// touchFrom: a touch as a server's status lists it (frontDoor.trips).
func touchFrom(sv Server, m map[string]any, now time.Time) (Touch, bool) {
	at := str(m["at"])
	when := parseTime(m["at"])
	if when.IsZero() {
		return Touch{}, false
	}
	t := Touch{Server: clip(sv.Name, 80), URL: sv.URL, At: when, Seen: now,
		Label: clip(str(m["label"]), 80), Type: clip(str(m["type"]), 10), Where: clip(str(m["where"]), 60),
		Method: clip(str(m["method"]), 10), Path: clip(str(m["path"]), 120), Query: clip(str(m["query"]), 240),
		Host: clip(str(m["host"]), 100), IP: clip(str(m["ip"]), 60), Agent: clip(str(m["agent"]), 160),
		Referer: clip(str(m["referer"]), 200), Lang: clip(str(m["lang"]), 60), Forwarded: clip(str(m["forwarded"]), 120),
		Headers: clip(str(m["headers"]), 400), Account: clip(str(m["account"]), 120), Status: intOf(m, "status")}
	t.ID = touchID(sv.URL, at, str(m["label"]), str(m["type"]), str(m["path"]), str(m["ip"]))
	return t, true
}

// touchStore: touches.json, kept in memory once read (the fleet view is its only writer).
type touchStore struct {
	mu     sync.Mutex
	loaded bool
	list   []Touch // newest first
}

func (s *Store) loadTouches() ([]Touch, error) {
	if s.touch.loaded {
		return s.touch.list, nil
	}
	var f struct {
		Touches []Touch `json:"touches"`
	}
	if err := readJSON(s.path("touches.json"), &f); err != nil {
		return nil, fmt.Errorf("touches.json can't be read: %w", err)
	}
	s.touch.list, s.touch.loaded = f.Touches, true
	return s.touch.list, nil
}

func (s *Store) saveTouches(list []Touch, now time.Time) error {
	// past their time, and beyond the most kept: the oldest first, tests and scanners before the rest
	keep := list[:0:0]
	for _, t := range list {
		limit := touchKeep
		if t.Verdict == "dealt" {
			limit = touchKeepReal
		}
		if now.Sub(t.At) <= limit {
			keep = append(keep, t)
		}
	}
	sort.SliceStable(keep, func(i, j int) bool { return keep[i].At.After(keep[j].At) })
	for len(keep) > maxTouches {
		drop := len(keep) - 1
		for i := len(keep) - 1; i >= 0; i-- {
			if keep[i].Verdict == "test" || keep[i].Verdict == "scanner" {
				drop = i
				break
			}
		}
		keep = append(keep[:drop], keep[drop+1:]...)
	}
	if err := writeJSON(s.path("touches.json"), map[string]any{"touches": keep}); err != nil {
		return err
	}
	s.touch.list, s.touch.loaded = keep, true
	return nil
}

// Touches: every touch kept, newest first (a copy).
func (s *Store) Touches() ([]Touch, error) {
	s.touch.mu.Lock()
	defer s.touch.mu.Unlock()
	list, err := s.loadTouches()
	return append([]Touch(nil), list...), err
}

// UpdateTouches changes touches.json in one locked step.
func (s *Store) UpdateTouches(now time.Time, change func([]Touch) ([]Touch, error)) error {
	s.touch.mu.Lock()
	defer s.touch.mu.Unlock()
	list, err := s.loadTouches()
	if err != nil {
		return err
	}
	list, err = change(append([]Touch(nil), list...))
	if err != nil {
		return err
	}
	return s.saveTouches(list, now)
}

// NoteTouches copies the touches a server listed that aren't kept yet (and an answer's status
// that arrived after the touch was first seen). Writes only when something is new.
func (s *Store) NoteTouches(sv Server, trips []any, now time.Time) error {
	if len(trips) == 0 {
		return nil
	}
	s.touch.mu.Lock()
	defer s.touch.mu.Unlock()
	list, err := s.loadTouches()
	if err != nil {
		return err
	}
	byID := map[string]int{}
	for i, t := range list {
		byID[t.ID] = i
	}
	var out []Touch
	changed := false
	for _, x := range trips {
		m, _ := x.(map[string]any)
		if m == nil {
			continue
		}
		t, ok := touchFrom(sv, m, now)
		if !ok {
			continue
		}
		if i, have := byID[t.ID]; have {
			if list[i].Status == 0 && t.Status != 0 {
				if out == nil {
					out = append([]Touch(nil), list...)
				}
				out[i].Status, changed = t.Status, true
			}
			continue
		}
		if out == nil {
			out = append([]Touch(nil), list...)
		}
		byID[t.ID] = len(out)
		out = append(out, t)
		changed = true
	}
	if !changed {
		return nil
	}
	return s.saveTouches(out, now)
}

// Mark is what was made of a touch, for the Front door and Checks.
type Mark struct {
	Verdict, By string
	At          time.Time
	Notes       int
}

// TouchMarks: every kept touch's mark, by id (nil when touches.json can't be read: all open).
func (s *Store) TouchMarks() map[string]Mark {
	list, err := s.Touches()
	if err != nil {
		return nil
	}
	out := make(map[string]Mark, len(list))
	for _, t := range list {
		m := Mark{Verdict: t.Verdict, Notes: len(t.Notes)}
		if n := len(t.Notes); n > 0 {
			m.By, m.At = t.Notes[n-1].By, t.Notes[n-1].At
		}
		out[t.ID] = m
	}
	return out
}

// Trail is what a practice server says one address did there (GET /api/steady/fleet/trail):
// from PocketBase's request log, requests with an account only counted.
type Trail struct {
	At   time.Time `json:"at"` // when the fleet view asked
	IP   string    `json:"ip"`
	Logs struct {
		Days int  `json:"days"`
		IP   bool `json:"ip"`
	} `json:"logs"`
	Total    int    `json:"total"`
	First    string `json:"first"`
	Last     string `json:"last"`
	SignedIn []struct {
		As    string `json:"as"`
		N     int    `json:"n"`
		First string `json:"first"`
		Last  string `json:"last"`
	} `json:"signedIn"`
	Requests []TrailRequest `json:"requests"`
	More     int            `json:"more"`
}

type TrailRequest struct {
	At      string `json:"at"`
	Method  string `json:"method"`
	Path    string `json:"path"`
	Status  int    `json:"status"`
	Agent   string `json:"agent"`
	Referer string `json:"referer"`
}

var errNoTrail = errors.New("the server keeps no trail for this address (it needs Steady 1.2.8, and keeps one only for an address that touched a tripwire in the last 30 days)")

// Trail asks a server what one address did there.
func (p *Poller) Trail(ctx context.Context, sv Server, ip string) (*Trail, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(sv.URL, "/")+"/api/steady/fleet/trail?ip="+url.QueryEscape(ip), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Steady-Fleet", sv.FleetKey)
	res, err := p.client.Do(req)
	if err != nil {
		return nil, errors.New("can't reach the server: " + shortErr(err))
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode == 404 {
		return nil, errNoTrail
	}
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("the server answered %d", res.StatusCode)
	}
	var t Trail
	if json.Unmarshal(b, &t) != nil {
		return nil, errors.New("the server's answer wasn't readable")
	}
	t.At = time.Now()
	return &t, nil
}

// Origin: what DNS says about an address (looked up only when someone opens a touch).
type Origin struct {
	Names                         []string // reverse DNS
	ASN, Network, Prefix, Country string   // from Team Cymru's IP-to-ASN lookup, over DNS
	Private                       string   // why there's nothing to look up
	Err                           string
}

var (
	cgnat   = mustCIDR("100.64.0.0/10")
	docNets = []*net.IPNet{mustCIDR("192.0.2.0/24"), mustCIDR("198.51.100.0/24"), mustCIDR("203.0.113.0/24"), mustCIDR("2001:db8::/32")}
)

func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic(err)
	}
	return n
}

// privateWhy: an address that isn't anyone's on the internet, and what that means here.
func privateWhy(ip net.IP) string {
	switch {
	case ip.IsLoopback():
		return "the server itself: it came from inside the server"
	case ip.IsPrivate() || ip.IsLinkLocalUnicast():
		return "a private address: from inside the server's own network (a container, the host), or through a proxy that passed on the wrong address"
	case cgnat.Contains(ip):
		return "a shared mobile or carrier network address: it can't be traced beyond the network"
	}
	for _, n := range docNets {
		if n.Contains(ip) {
			return "an address kept for examples and tests"
		}
	}
	return ""
}

// cymruName: the DNS name Team Cymru answers for an address.
func cymruName(ip net.IP) string {
	if v4 := ip.To4(); v4 != nil {
		return fmt.Sprintf("%d.%d.%d.%d.origin.asn.cymru.com", v4[3], v4[2], v4[1], v4[0])
	}
	h := hex.EncodeToString(ip.To16())
	var b strings.Builder
	for i := len(h) - 1; i >= 0; i-- {
		b.WriteByte(h[i])
		b.WriteByte('.')
	}
	return b.String() + "origin6.asn.cymru.com"
}

func txtFields(s string) []string {
	parts := strings.Split(s, "|")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

// lookupOrigin asks DNS: the address's names, and its network (Team Cymru). A few seconds at most.
func lookupOrigin(ctx context.Context, addr string) Origin {
	ip := net.ParseIP(addr)
	if ip == nil {
		return Origin{Err: "not an address"}
	}
	if why := privateWhy(ip); why != "" {
		return Origin{Private: why}
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	var o Origin
	r := net.DefaultResolver
	if names, err := r.LookupAddr(ctx, addr); err == nil {
		for _, n := range names {
			o.Names = append(o.Names, clip(strings.TrimSuffix(n, "."), 120))
		}
	}
	txt, err := r.LookupTXT(ctx, cymruName(ip))
	if err != nil || len(txt) == 0 {
		o.Err = "its network couldn't be looked up just now"
		return o
	}
	f := txtFields(txt[0])
	if len(f) >= 3 {
		o.ASN = strings.Fields(f[0] + " ")[0]
		o.Prefix, o.Country = clip(f[1], 50), clip(f[2], 4)
	}
	if o.ASN != "" {
		if as, err := r.LookupTXT(ctx, "AS"+o.ASN+".asn.cymru.com"); err == nil && len(as) > 0 {
			if g := txtFields(as[0]); len(g) >= 5 {
				o.Network = clip(g[4], 120)
			}
		}
	}
	return o
}

// originCache keeps lookups for an hour.
type originCache struct {
	mu sync.Mutex
	m  map[string]struct {
		o  Origin
		at time.Time
	}
}

func (c *originCache) get(ctx context.Context, ip string, look func(context.Context, string) Origin) Origin {
	c.mu.Lock()
	if c.m == nil {
		c.m = map[string]struct {
			o  Origin
			at time.Time
		}{}
	}
	if x, ok := c.m[ip]; ok && time.Since(x.at) < time.Hour {
		c.mu.Unlock()
		return x.o
	}
	c.mu.Unlock()
	o := look(ctx, ip)
	c.mu.Lock()
	if len(c.m) > 500 {
		clear(c.m)
	}
	c.m[ip] = struct {
		o  Origin
		at time.Time
	}{o, time.Now()}
	c.mu.Unlock()
	return o
}

// tools: what a User-Agent says made the request (the first that matches).
var tools = []struct{ match, says string }{
	{"censys", "Censys, an internet-wide survey scanner: it looks at every server, not Steady in particular"},
	{"shodan", "Shodan, an internet-wide survey scanner"},
	{"expanse", "Palo Alto's Expanse, an internet-wide survey scanner"},
	{"internet-measurement", "an internet measurement scanner (it looks at every server)"},
	{"shadowserver", "The Shadowserver Foundation's scanner (it looks at every server and reports problems to their owners)"},
	{"leakix", "LeakIX, a scanner that looks for exposed files and services"},
	{"binaryedge", "BinaryEdge, an internet-wide scanner"},
	{"onyphe", "Onyphe, an internet-wide scanner"},
	{"modat", "Modat, an internet-wide scanner"},
	{"zgrab", "ZGrab, the tool most internet-wide scanners are built on"},
	{"nuclei", "Nuclei, a vulnerability scanner: someone running checks for known weaknesses"},
	{"sqlmap", "sqlmap, a tool for breaking into databases: someone attacking on purpose"},
	{"nikto", "Nikto, a web vulnerability scanner"},
	{"wpscan", "WPScan, a WordPress scanner (looking for WordPress sites to break into)"},
	{"nmap", "Nmap, a network scanner"},
	{"masscan", "masscan, a fast port scanner"},
	{"gobuster", "Gobuster, a tool that guesses paths"},
	{"dirbuster", "DirBuster, a tool that guesses paths"},
	{"feroxbuster", "feroxbuster, a tool that guesses paths"},
	{"ffuf", "ffuf, a tool that guesses paths"},
	{"wfuzz", "wfuzz, a tool that guesses paths"},
	{"hydra", "Hydra, a password-guessing tool"},
	{"googlebot", "Google's crawler (or something calling itself that: the real one keeps out of what robots.txt lists)"},
	{"bingbot", "Bing's crawler (or something calling itself that)"},
	{"bot", "a crawler or bot of some kind"},
	{"curl/", "curl, a command-line tool: someone typing commands, or a script"},
	{"wget", "Wget, a command-line download tool"},
	{"python", "a Python script"},
	{"go-http-client", "a program written in Go (many scanners are)"},
	{"okhttp", "an Android app or a Java program"},
	{"java", "a Java program"},
	{"node", "a Node.js script"},
	{"axios", "a JavaScript program"},
	{"postman", "Postman, a tool for trying out APIs by hand"},
	{"insomnia", "Insomnia, a tool for trying out APIs by hand"},
	{"powershell", "PowerShell, on Windows"},
	{"firefox/", "a web browser (Firefox), or something posing as one"},
	{"edg/", "a web browser (Edge), or something posing as one"},
	{"chrome/", "a web browser (Chrome or one like it), or something posing as one"},
	{"safari/", "a web browser (Safari), or something posing as one"},
	{"mozilla/", "something posing as a web browser (it says so, and little else)"},
}

// toolOf: what made the request, going by what it said.
func toolOf(agent string) string {
	a := strings.ToLower(agent)
	if strings.TrimSpace(a) == "" {
		return "it didn't say: scripts and scanners often send nothing"
	}
	for _, t := range tools {
		if strings.Contains(a, t.match) {
			return t.says
		}
	}
	return "it doesn't say anything recognisable"
}

// hostingWords: networks whose addresses are rented servers, not homes or offices.
var hostingWords = []string{"amazon", "aws", "google", "microsoft", "azure", "digitalocean", "ovh", "hetzner", "linode", "akamai",
	"vultr", "choopa", "contabo", "scaleway", "online s.a.s", "leaseweb", "m247", "tencent", "alibaba", "aliyun", "oracle",
	"hostinger", "ionos", "cloud", "hosting", "datacenter", "data center", "server", "vps", "colo", "xneelo"}

func looksHosting(network string) bool {
	n := strings.ToLower(network)
	for _, w := range hostingWords {
		if strings.Contains(n, w) {
			return true
		}
	}
	return false
}
