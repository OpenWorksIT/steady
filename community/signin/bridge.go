// The sign-in itself. The forum opens only inside Steady, in the Community tab of the app and the
// web app, and only for whoever is signed in to Steady there:
//
//  1. The tab asks its practice's Steady server for a note: who is signed in, signed with the
//     key that server shares with the bridge. It opens /enter?p=<note>&s=<signature>.
//  2. The bridge finds the practice whose key signed it, checks it, and keeps it for two minutes
//     under a cookie only this browser has. It sends the browser to the forum's /session/sso.
//  3. The forum sends it back to /discourse?sso=..&sig=.. (DiscourseConnect): what the forum
//     asks for, signed with the forum's secret. The bridge checks that, takes the note the
//     cookie points to, and sends the browser to the forum's /session/sso_login with the
//     person's forum account details, signed with the forum's secret. They're in.
//
// Anyone reaching /discourse any other way (the forum opened straight in a browser) has no note
// and is told to open Steady.
//
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

//go:embed web
var webFS embed.FS

const (
	cookieName  = "steady_entry"
	maxNoteAge  = 5 * time.Minute // a note never claims to last longer than this
	clockSlack  = time.Minute     // between this server's clock and a practice's
	windowLen   = 10 * time.Minute
	windowLimit = 120 // requests per address per window
)

var (
	reNonce = regexp.MustCompile(`^[A-Za-z0-9_-]{8,128}$`)
	reSub   = regexp.MustCompile(`^[a-z0-9]{15}$`)
	reJti   = regexp.MustCompile(`^[A-Za-z0-9]{16,64}$`)
	reEntry = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
)

// note is what a practice's Steady server says about the person (server/pb_hooks/lib/community.js).
type note struct {
	V     int    `json:"v"`
	Aud   string `json:"aud"`
	Jti   string `json:"jti"`
	Sub   string `json:"sub"`
	Email string `json:"email"`
	Name  string `json:"name"`
	Role  string `json:"role"`
	Iat   int64  `json:"iat"`
	Exp   int64  `json:"exp"`
}

type App struct {
	cfg     *ConfigFile
	entries *Entries
	proxy   string
	now     func() time.Time
	pages   *template.Template

	proxyMu   sync.Mutex
	proxyIPs  map[string]bool
	proxySeen time.Time

	limitMu sync.Mutex
	counts  map[string]*window
}

type window struct {
	start time.Time
	n     int
}

func NewApp(cfg *ConfigFile, entries *Entries, proxy string) *App {
	return &App{
		cfg: cfg, entries: entries, proxy: proxy, now: time.Now,
		pages:  template.Must(template.ParseFS(webFS, "web/*.html")),
		counts: map[string]*window{},
	}
}

func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /enter", a.enter)
	mux.HandleFunc("GET /discourse", a.discourse)
	mux.HandleFunc("GET /outside", a.outside)
	mux.HandleFunc("GET /signed-out", a.signedOut)
	mux.HandleFunc("GET /app.css", a.file("web/app.css", "text/css; charset=utf-8"))
	mux.HandleFunc("GET /app.js", a.file("web/app.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("GET /healthz", a.healthz)
	mux.HandleFunc("GET /version", a.version)
	mux.HandleFunc("GET /{$}", a.outside)
	return a.headers(mux)
}

func (a *App) headers(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// its pages show inside Steady's Community tab: only the practices' Steady may frame them
		ancestors := "'self'"
		if cfg, err := a.cfg.Get(); err == nil {
			for _, p := range cfg.Practices {
				ancestors += " " + p.URL
			}
		}
		hd := w.Header()
		hd.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; frame-ancestors "+ancestors+"; base-uri 'none'; form-action 'none'")
		hd.Set("X-Content-Type-Options", "nosniff")
		// the addresses carry Steady's note: never passed on to the next site
		hd.Set("Referrer-Policy", "no-referrer")
		hd.Set("Cache-Control", "no-store")
		hd.Set("Strict-Transport-Security", "max-age=31536000")
		h.ServeHTTP(w, r)
	})
}

/* ---------------------------------------------------------------- the steps */

// enter: steps 1 and 2, Steady's note in, on to the forum.
func (a *App) enter(w http.ResponseWriter, r *http.Request) {
	cfg, ok := a.config(w)
	if !ok || !a.allow(w, r) {
		return
	}
	// only from Steady itself: its frame (same site) or the phone app's own web view (none). A
	// link on another site or in an email can't plant someone else's sign-in in this browser.
	if s := r.Header.Get("Sec-Fetch-Site"); s != "" && s != "same-site" && s != "same-origin" && s != "none" {
		a.problem(w, http.StatusForbidden, "Steady Community opens inside Steady", "Open Steady, the app or the web app, and choose Community.", "entry from another site ("+s+")")
		return
	}
	q := r.URL.Query()
	body, sig := q.Get("p"), q.Get("s")
	var n note
	if len(body) > 4096 || json.Unmarshal([]byte(body), &n) != nil {
		a.problem(w, http.StatusBadRequest, "The community didn't open", "Close it and choose Community in Steady again.", "note isn't readable")
		return
	}
	// the practice whose key signed it (each practice has its own)
	var p *Practice
	for i := range cfg.Practices {
		if signedBy(cfg.Practices[i].Key, body, sig) {
			p = &cfg.Practices[i]
			break
		}
	}
	if p == nil {
		a.problem(w, http.StatusForbidden, "The community didn't open",
			"Your practice's Steady isn't set up for the community, or its key doesn't match. Please tell OpenWorks IT (info@openworks.co.za).", "no practice's key signed the note")
		return
	}
	if title, text, why := a.checkNote(n, cfg, p); why != "" {
		a.problem(w, http.StatusForbidden, title, text, why+" ("+p.ID+")")
		return
	}
	id, err := a.entries.Add(n, p.ID, a.clientKey(r))
	if err == errUsed {
		a.problem(w, http.StatusForbidden, "The community didn't open", "That sign-in was used already. Choose Community in Steady again.", err.Error()+" ("+p.ID+")")
		return
	}
	if err != nil {
		a.problem(w, http.StatusTooManyRequests, "The community didn't open", "Close it and choose Community in Steady again in a minute.", err.Error()+" ("+p.ID+")")
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: id, Path: "/discourse", MaxAge: 120, Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	// always through the forum's sign-in, so the forum shows whoever is in Steady now (another
	// psychologist may have used this browser before)
	http.Redirect(w, r, cfg.Forum+"/session/sso", http.StatusSeeOther)
}

// discourse: step 3, the forum asks; the note this browser brought answers.
func (a *App) discourse(w http.ResponseWriter, r *http.Request) {
	cfg, ok := a.config(w)
	if !ok || !a.allow(w, r) {
		return
	}
	q := r.URL.Query()
	sso := q.Get("sso")
	if len(sso) > 4096 || !signedBy(cfg.ForumSecret, sso, q.Get("sig")) {
		a.problem(w, http.StatusBadRequest, "The community didn't open", "Close it and choose Community in Steady again.", "bad forum signature")
		return
	}
	raw, err := base64.StdEncoding.DecodeString(strings.NewReplacer("\n", "", "\r", "").Replace(sso))
	if err != nil {
		a.problem(w, http.StatusBadRequest, "The community didn't open", "Close it and choose Community in Steady again.", "forum payload isn't base64")
		return
	}
	asked, err := url.ParseQuery(string(raw))
	nonce, returnTo := asked.Get("nonce"), asked.Get("return_sso_url")
	if err != nil || !reNonce.MatchString(nonce) || returnTo != cfg.Forum+"/session/sso_login" {
		a.problem(w, http.StatusBadRequest, "The community didn't open", "Close it and choose Community in Steady again.", "forum payload: no nonce or another return address")
		return
	}
	var e entry
	found := false
	if c, err := r.Cookie(cookieName); err == nil && reEntry.MatchString(c.Value) {
		e, found = a.entries.Take(c.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/discourse", MaxAge: -1, Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	p := cfg.practice(e.practice)
	if !found || p == nil {
		// the forum opened some other way than through Steady (or its session ran out in the tab)
		a.render(w, http.StatusForbidden, "message.html", outsidePage)
		return
	}
	n := e.note
	external := p.ID + ":" + n.Sub
	add, remove := groupsFor(n.Role, p, cfg)
	title := p.Name
	if n.Role == "support" {
		title = "OpenWorks IT"
	}
	out := url.Values{
		"nonce":         {nonce},
		"external_id":   {external},
		"email":         {strings.ToLower(n.Email)},
		"add_groups":    {strings.Join(add, ",")},
		"remove_groups": {strings.Join(remove, ",")},
		// shown beside their name, so nobody passes as someone from another practice
		"title": {title},
		// every address is on exactly one list in the settings, so it is vouched for: the forum
		// takes it as it is (no email to check it), and an account already there with it carries on
		"require_activation": {"false"},
	}
	if name := cleanName(n.Name); name != "" {
		out.Set("name", name)
	}
	payload := base64.StdEncoding.EncodeToString([]byte(out.Encode()))
	log.Printf("signin: %s signed in to the forum as %s (%s)", external, n.Role, p.Name)
	http.Redirect(w, r, returnTo+"?"+url.Values{"sso": {payload}, "sig": {sign(cfg.ForumSecret, payload)}}.Encode(), http.StatusSeeOther)
}

// checkNote: anything wrong with a correctly signed note, as a title and text for the person
// and a reason for the log; why is "" when it's fine.
func (a *App) checkNote(n note, cfg *Config, p *Practice) (title, text, why string) {
	now := a.now()
	iat, exp := time.Unix(n.Iat, 0), time.Unix(n.Exp, 0)
	email := strings.ToLower(n.Email)
	switch {
	case n.V != 1:
		return "Steady needs an update", p.Name + "'s Steady needs an update before the community opens. Please tell OpenWorks IT.", "note version"
	case n.Aud != cfg.URL:
		return "The community didn't open", p.Name + "'s Steady sends people to " + n.Aud + ", not here. Please tell OpenWorks IT (STEADY_COMMUNITY_SIGNIN).", "note for another bridge"
	case now.After(exp.Add(clockSlack)):
		return "That took too long", "Close the community and choose Community in Steady again.", "note expired"
	case iat.After(now.Add(clockSlack)) || exp.Before(iat) || exp.Sub(iat) > maxNoteAge:
		return "The community didn't open", "The clocks of the community and " + p.Name + "'s Steady don't agree. Please tell OpenWorks IT.", "note times"
	case !reJti.MatchString(n.Jti) || !reSub.MatchString(n.Sub):
		return "The community didn't open", "Close it and choose Community in Steady again.", "note ids"
	case !validEmail(email):
		return "This email address can't be used", "Your Steady account's email address can't be used in the community. Ask your practice to check it.", "note email"
	// one list per practice covers its staff: psychologists and practice administrators
	case (n.Role == "clinician" || n.Role == "admin") && !listed(p.Emails, email):
		return "This address isn't on the community's list", "Your email address isn't one " + p.Name + " has listed for the community. Ask the community lead to add it.", "email not on the practice's list"
	case n.Role == "support" && !p.Support:
		return forWhom, "OpenWorks support comes in through OpenWorks' own server, not " + p.Name + "'s.", "support from a practice not marked for it"
	case n.Role == "support" && !listed(cfg.OpenWorks, email):
		return "This address isn't on the community's list", "Only OpenWorks IT's listed addresses come in as OpenWorks support.", "support address not on the OpenWorks list"
	case n.Role != "clinician" && n.Role != "admin" && n.Role != "support":
		return forWhom, "Only psychologists, practice administrators and OpenWorks IT can open Steady Community.", "role " + n.Role
	}
	return "", "", ""
}

const forWhom = "The community is for psychologists, practice administrators and OpenWorks IT"

// groupsFor: psychologists join clinicians and their practice's own groups; practice
// administrators join practice-admins only (it sees the Steady manual, nothing else); OpenWorks
// support joins openworks. Everyone leaves every other group the bridge hands out, so someone
// whose role changed, or whose address moved to another practice's list (or to OpenWorks'),
// keeps nothing of the old one.
func groupsFor(role string, p *Practice, cfg *Config) (add, remove []string) {
	switch role {
	case "clinician":
		add = append([]string{"clinicians"}, p.Groups...)
	case "admin":
		// never clinicians or the practice's own groups: those are for its psychologists
		add = []string{"practice-admins"}
	case "support":
		add = []string{"openworks"}
	}
	adding := map[string]bool{}
	for _, g := range add {
		adding[g] = true
	}
	all := []string{"clinicians", "practice-admins", "openworks"}
	for _, q := range cfg.Practices {
		all = append(all, q.Groups...)
	}
	seen := map[string]bool{}
	for _, g := range all {
		if !adding[g] && !seen[g] {
			seen[g] = true
			remove = append(remove, g)
		}
	}
	return add, remove
}

// cleanName: the name as Steady has it, on one line, without control or direction-changing
// characters, at most 100 characters.
func cleanName(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case unicode.IsSpace(r):
			return ' '
		case unicode.IsControl(r) || unicode.Is(unicode.Cf, r):
			return -1
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 100 {
		s = string(r[:100])
	}
	return s
}

/* ---------------------------------------------------------------- signatures */

func sign(key, text string) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(text))
	return hex.EncodeToString(m.Sum(nil))
}

// signedBy: sig is text's HMAC-SHA256 under key, in hex (compared in constant time).
func signedBy(key, text, sig string) bool {
	got, err := hex.DecodeString(strings.ToLower(sig))
	if err != nil || len(got) != sha256.Size || text == "" {
		return false
	}
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(text))
	return hmac.Equal(got, m.Sum(nil))
}

/* ---------------------------------------------------------------- pages */

// the community opened some other way than through Steady; inside Steady's tab the page tells
// the tab (web/app.js), which opens it again for whoever is signed in
var outsidePage = map[string]any{
	"Title":   "Steady Community opens inside Steady",
	"Text":    "Open Steady, the app or the web app, and choose Community.",
	"Message": "sign-in",
}

func (a *App) outside(w http.ResponseWriter, r *http.Request) {
	a.render(w, http.StatusOK, "message.html", outsidePage)
}

func (a *App) signedOut(w http.ResponseWriter, r *http.Request) {
	a.render(w, http.StatusOK, "message.html", map[string]any{
		"Title":   "You've signed out of the community",
		"Text":    "Choose Community in Steady to come back.",
		"Message": "signed-out",
	})
}

func (a *App) problem(w http.ResponseWriter, status int, title, text, why string) {
	if why != "" {
		log.Printf("signin: refused: %s", why)
	}
	a.render(w, status, "message.html", map[string]any{"Title": title, "Text": text})
}

// config: the settings, or a page saying the bridge isn't ready (the reason goes to the log).
func (a *App) config(w http.ResponseWriter) (*Config, bool) {
	cfg, err := a.cfg.Get()
	if err != nil {
		log.Printf("signin: %v", err)
		a.render(w, http.StatusServiceUnavailable, "message.html", map[string]any{
			"Title": "The community isn't available", "Text": "Please try again later, or tell OpenWorks IT (info@openworks.co.za).",
		})
		return nil, false
	}
	return cfg, true
}

func (a *App) render(w http.ResponseWriter, status int, name string, data map[string]any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := a.pages.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("signin: page %s: %v", name, err)
	}
}

func (a *App) file(name, kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, _ := webFS.ReadFile(name)
		w.Header().Set("Content-Type", kind)
		w.Header().Set("Cache-Control", "max-age=3600")
		w.Write(b)
	}
}

// healthz: 200 when the settings are good; why not goes to the log only.
func (a *App) healthz(w http.ResponseWriter, r *http.Request) {
	if _, err := a.cfg.Get(); err != nil {
		log.Printf("signin: %v", err)
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.Write([]byte("ok\n"))
}

// version: which release and code this bridge was built from, for the fleet view to compare with
// its own release (deploy/code-of.sh). Nothing else: no settings, no practices.
func (a *App) version(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]string{"version": buildVersion, "code": buildCode})
}

/* ---------------------------------------------------------------- visitors */

// allow: at most windowLimit requests per address (IPv6: per /64) per 10 minutes.
func (a *App) allow(w http.ResponseWriter, r *http.Request) bool {
	key := a.clientKey(r)
	now := a.now()
	a.limitMu.Lock()
	if len(a.counts) > 20000 {
		for k, c := range a.counts {
			if now.Sub(c.start) > windowLen {
				delete(a.counts, k)
			}
		}
		// still full (many addresses at once): start counting afresh rather than grow without end
		if len(a.counts) > 50000 {
			a.counts = map[string]*window{}
		}
	}
	c := a.counts[key]
	if c == nil || now.Sub(c.start) > windowLen {
		c = &window{start: now}
		a.counts[key] = c
	}
	c.n++
	over := c.n > windowLimit
	a.limitMu.Unlock()
	if over {
		a.problem(w, http.StatusTooManyRequests, "Too many tries", "Please wait ten minutes, then choose Community in Steady again.", "rate limit for "+key)
		return false
	}
	return true
}

// clientKey: the visitor's address as Caddy saw it (only Caddy's X-Forwarded-For is believed);
// IPv6 addresses by their /64, as one household or phone gets a whole /64.
func (a *App) clientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if a.isProxy(host) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(ip) != nil {
				host = ip
			}
		}
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return host
	}
	if ip.To4() == nil {
		return ip.Mask(net.CIDRMask(64, 128)).String() + "/64"
	}
	return ip.String()
}

// isProxy: the connection comes from the trusted reverse proxy (looked up again every minute,
// as container addresses can change).
func (a *App) isProxy(ip string) bool {
	if a.proxy == "" {
		return false
	}
	a.proxyMu.Lock()
	defer a.proxyMu.Unlock()
	if a.proxyIPs == nil || time.Since(a.proxySeen) > time.Minute {
		a.proxyIPs = map[string]bool{}
		if p := net.ParseIP(a.proxy); p != nil {
			a.proxyIPs[p.String()] = true
		} else if addrs, err := net.LookupHost(a.proxy); err == nil {
			for _, x := range addrs {
				if p := net.ParseIP(x); p != nil {
					a.proxyIPs[p.String()] = true
				}
			}
		}
		a.proxySeen = time.Now()
	}
	p := net.ParseIP(ip)
	return p != nil && a.proxyIPs[p.String()]
}
