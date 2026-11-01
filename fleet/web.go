// The fleet view's pages: sign-in (name, password, authenticator code), the overview of every
// practice server, one server's detail with Check / Update / Restart, and the audit log.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"crypto/subtle"
	"embed"
	"html/template"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

const cookieName = "__Host-fleet"

type App struct {
	store    *Store
	poller   *Poller
	sessions *Sessions
	limiter  *Limiter
	pages    *template.Template
	now      func() time.Time
	// at most two slow password checks at a time, whatever arrives
	hashing chan struct{}
	// the reverse proxy (Caddy) whose X-Forwarded-For is believed: a host name or an address;
	// "" = believe nobody and use the connection's own address
	proxy     string
	proxyMu   sync.Mutex
	proxyIPs  map[string]bool
	proxySeen time.Time
	// tests run without TLS
	insecureCookie bool
}

func NewApp(store *Store, poller *Poller, trustedProxy string) *App {
	t := template.Must(template.New("").ParseFS(webFS, "web/*.html"))
	return &App{store: store, poller: poller, sessions: NewSessions(), limiter: NewLimiter(), pages: t, now: time.Now,
		hashing: make(chan struct{}, 2), proxy: trustedProxy}
}

func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /app.css", a.css)
	mux.HandleFunc("GET /login", a.loginPage)
	mux.HandleFunc("POST /login", a.login)
	mux.HandleFunc("POST /logout", a.signedIn(a.logout))
	mux.HandleFunc("GET /{$}", a.signedIn(a.overview))
	mux.HandleFunc("GET /s/{n}", a.signedIn(a.detail))
	mux.HandleFunc("POST /s/{n}/action", a.signedIn(a.action))
	mux.HandleFunc("GET /audit", a.signedIn(a.audit))
	return headers(mux)
}

// headers: nothing from elsewhere, no framing, no caching, no referrer; forms are small.
func headers(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hd := w.Header()
		hd.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("X-Frame-Options", "DENY")
		hd.Set("Referrer-Policy", "no-referrer")
		hd.Set("Cache-Control", "no-store")
		hd.Set("Strict-Transport-Security", "max-age=31536000")
		if r.Method == "POST" {
			r.Body = http.MaxBytesReader(w, r.Body, 4096)
		}
		h.ServeHTTP(w, r)
	})
}

// isProxy: the connection comes from the trusted reverse proxy (its addresses looked up again
// every minute, as container addresses can change).
func (a *App) isProxy(ip string) bool {
	if a.proxy == "" {
		return false
	}
	a.proxyMu.Lock()
	defer a.proxyMu.Unlock()
	if a.proxyIPs == nil || time.Since(a.proxySeen) > time.Minute {
		a.proxyIPs = map[string]bool{}
		if net.ParseIP(a.proxy) != nil {
			a.proxyIPs[net.ParseIP(a.proxy).String()] = true
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

func (a *App) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if a.isProxy(host) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	return host
}

func (a *App) render(w http.ResponseWriter, name string, data map[string]any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := a.pages.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, "page error", 500)
	}
}

func (a *App) css(w http.ResponseWriter, r *http.Request) {
	b, _ := webFS.ReadFile("web/app.css")
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	w.Header().Set("Cache-Control", "max-age=3600")
	w.Write(b)
}

type handler func(w http.ResponseWriter, r *http.Request, s *Session)

// signedIn lets a request through only with a live session; changes also need its CSRF token
// and a same-origin request.
func (a *App) signedIn(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(cookieName)
		var s *Session
		if err == nil {
			// the pages' own refresh (?auto=1) doesn't count as activity
			s = a.sessions.Get(c.Value, a.now(), r.URL.Query().Get("auto") != "1")
		}
		if s != nil {
			// someone removed from users.json is signed out at once
			if u, err := a.store.User(s.User); err != nil || u == nil {
				a.sessions.End(c.Value)
				s = nil
			}
		}
		if s == nil {
			if r.Method == "GET" {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
			} else {
				http.Error(w, "Signed out: sign in again.", http.StatusUnauthorized)
			}
			return
		}
		if r.Method != "GET" {
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" ||
				subtle.ConstantTimeCompare([]byte(r.PostFormValue("csrf")), []byte(s.CSRF)) != 1 {
				http.Error(w, "This form has expired: go back, reload and try again.", http.StatusForbidden)
				return
			}
		}
		h(w, r, s)
	}
}

func (a *App) loginPage(w http.ResponseWriter, r *http.Request) {
	a.render(w, "login.html", map[string]any{"Error": ""})
}

func (a *App) refuse(w http.ResponseWriter, status int, msg string) {
	w.WriteHeader(status)
	a.render(w, "login.html", map[string]any{"Error": msg})
}

const wrongSignIn = "That name, password and code didn't match."

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	ip := a.clientIP(r)
	now := a.now()
	ipKey := addrKey(ip)
	// the attempt takes its slot first: a burst can't all slip past the limit
	if !a.limiter.Take(ipKey, failsPerIP, now) {
		a.refuse(w, http.StatusTooManyRequests, "Too many wrong tries. Wait 15 minutes.")
		return
	}
	name := strings.ToLower(strings.TrimSpace(r.PostFormValue("name")))
	if validName(name) != nil {
		a.refuse(w, http.StatusUnauthorized, wrongSignIn)
		return
	}
	userKey := "user:" + name
	if a.limiter.Blocked(userKey, failsPerUser, now) {
		a.refuse(w, http.StatusTooManyRequests, "Too many wrong codes for this name. Wait 15 minutes.")
		return
	}
	a.hashing <- struct{}{}
	// a burst that queued here: check again now that it's this request's turn
	if a.limiter.Blocked(userKey, failsPerUser, now) {
		<-a.hashing
		a.refuse(w, http.StatusTooManyRequests, "Too many wrong codes for this name. Wait 15 minutes.")
		return
	}
	u, err := a.store.User(name)
	pwOK := err == nil && PasswordOK(u, r.PostFormValue("password"))
	<-a.hashing
	if err != nil {
		http.Error(w, "users.json can't be read", 500)
		return
	}
	if !pwOK {
		a.store.Audit(name, ip, "sign-in failed", "password")
		a.refuse(w, http.StatusUnauthorized, wrongSignIn)
		return
	}
	// the password was right: wrong codes now count against the name too
	ok, err := a.store.UseCode(u.Name, r.PostFormValue("code"), now)
	if err != nil {
		http.Error(w, "users.json can't be written", 500)
		return
	}
	if !ok {
		a.limiter.Take(userKey, failsPerUser, now)
		a.store.Audit(u.Name, ip, "sign-in failed", "authenticator code")
		a.refuse(w, http.StatusUnauthorized, wrongSignIn)
		return
	}
	a.limiter.Give(ipKey, now)
	id, _ := a.sessions.New(u.Name, now)
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: id, Path: "/", HttpOnly: true, Secure: !a.insecureCookie, SameSite: http.SameSiteStrictMode, MaxAge: int(sessionMax.Seconds())})
	a.store.Audit(u.Name, ip, "signed in", "")
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request, s *Session) {
	if c, err := r.Cookie(cookieName); err == nil {
		a.sessions.End(c.Value)
	}
	a.store.Audit(s.User, a.clientIP(r), "signed out", "")
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", HttpOnly: true, Secure: !a.insecureCookie, SameSite: http.SameSiteStrictMode, MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (a *App) overview(w http.ResponseWriter, r *http.Request, s *Session) {
	sts, cfgErr := a.poller.Snapshot()
	now := a.now()
	rows := make([]Row, 0, len(sts))
	counts := map[string]int{}
	for i, st := range sts {
		row := makeRow(i, st, now)
		counts[row.Level]++
		rows = append(rows, row)
	}
	w.Header().Set("Refresh", "60; url=/?auto=1")
	a.render(w, "overview.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Rows": rows, "ConfigError": cfgErr, "Counts": counts, "Now": now.Format("15:04"),
		"Community": makeCommunity(a.poller.CommunitySnapshot(), now)})
}

func (a *App) server(r *http.Request) (*Status, int, bool) {
	n, err := strconv.Atoi(r.PathValue("n"))
	sts, _ := a.poller.Snapshot()
	if err != nil || n < 0 || n >= len(sts) {
		return nil, 0, false
	}
	return sts[n], n, true
}

func (a *App) detail(w http.ResponseWriter, r *http.Request, s *Session) {
	st, n, ok := a.server(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	now := a.now()
	msg := a.sessions.TakeFlash(s)
	w.Header().Set("Refresh", "60; url=/s/"+strconv.Itoa(n)+"?auto=1")
	a.render(w, "detail.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Row": makeRow(n, st, now), "Facts": facts(st, now), "Msg": msg})
}

var actions = map[string]string{"check": "check for updates", "update": "install the latest signed release", "restart": "restart Steady"}

func (a *App) action(w http.ResponseWriter, r *http.Request, s *Session) {
	st, n, ok := a.server(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	back := "/s/" + strconv.Itoa(n)
	act := r.PostFormValue("action")
	what, known := actions[act]
	if !known {
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}
	if act != "check" && r.PostFormValue("confirm") != st.Server.Name {
		a.sessions.SetFlash(s, "Type the practice's name exactly to "+what+".")
		http.Redirect(w, r, back, http.StatusSeeOther)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	err := a.poller.Request(ctx, st.Server, act)
	msg := "Asked " + st.Server.Name + " to " + what + ". The server does it within a minute; this page shows the result once it's done."
	detail := "ok"
	if err != nil {
		msg, detail = "Couldn't ask "+st.Server.Name+": "+err.Error(), err.Error()
	}
	a.sessions.SetFlash(s, msg)
	a.store.Audit(s.User, a.clientIP(r), act, st.Server.Name+": "+detail)
	http.Redirect(w, r, back, http.StatusSeeOther)
}

func (a *App) audit(w http.ResponseWriter, r *http.Request, s *Session) {
	a.render(w, "audit.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Lines": a.store.RecentAudit(200)})
}
