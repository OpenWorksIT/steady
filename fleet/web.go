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
	// behind Caddy: the visitor's address is the last X-Forwarded-For entry
	trustProxy bool
	// tests run without TLS
	insecureCookie bool
}

func NewApp(store *Store, poller *Poller, trustProxy bool) *App {
	t := template.Must(template.New("").ParseFS(webFS, "web/*.html"))
	return &App{store: store, poller: poller, sessions: NewSessions(), limiter: NewLimiter(), pages: t, now: time.Now, trustProxy: trustProxy}
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

// headers: nothing from elsewhere, no framing, no caching, no referrer.
func headers(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hd := w.Header()
		hd.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("X-Frame-Options", "DENY")
		hd.Set("Referrer-Policy", "no-referrer")
		hd.Set("Cache-Control", "no-store")
		hd.Set("Strict-Transport-Security", "max-age=31536000")
		h.ServeHTTP(w, r)
	})
}

func (a *App) clientIP(r *http.Request) string {
	if a.trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
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
			s = a.sessions.Get(c.Value, a.now())
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

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	ip := a.clientIP(r)
	name := strings.TrimSpace(r.PostFormValue("name"))
	now := a.now()
	if a.limiter.Blocked(ip, name, now) {
		a.store.Audit(name, ip, "sign-in refused", "too many wrong tries")
		w.WriteHeader(http.StatusTooManyRequests)
		a.render(w, "login.html", map[string]any{"Error": "Too many wrong tries. Wait 15 minutes."})
		return
	}
	u, err := a.store.User(name)
	if err != nil {
		http.Error(w, "users.json can't be read", 500)
		return
	}
	pwOK := PasswordOK(u, r.PostFormValue("password"))
	step := int64(0)
	if pwOK {
		step = TOTPCheck(u, r.PostFormValue("code"), now)
	}
	if !pwOK || step == 0 {
		a.limiter.Fail(ip, name, now)
		a.store.Audit(name, ip, "sign-in failed", "")
		w.WriteHeader(http.StatusUnauthorized)
		a.render(w, "login.html", map[string]any{"Error": "That name, password and code didn't match."})
		return
	}
	if err := a.store.UseStep(u.Name, step); err != nil {
		http.Error(w, "users.json can't be written", 500)
		return
	}
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
	w.Header().Set("Refresh", "60")
	a.render(w, "overview.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Rows": rows, "ConfigError": cfgErr, "Counts": counts, "Now": now.Format("15:04")})
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
	w.Header().Set("Refresh", "60")
	a.render(w, "detail.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Row": makeRow(n, st, now), "Facts": facts(st, now), "Msg": r.URL.Query().Get("msg")})
}

var actions = map[string]string{"check": "check for updates", "update": "install the latest signed release", "restart": "restart Steady"}

func (a *App) action(w http.ResponseWriter, r *http.Request, s *Session) {
	st, n, ok := a.server(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	act := r.PostFormValue("action")
	what, known := actions[act]
	if !known {
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}
	if act != "check" && r.PostFormValue("confirm") != st.Server.Name {
		http.Redirect(w, r, "/s/"+strconv.Itoa(n)+"?msg="+urlq("Type the practice's name exactly to "+what+"."), http.StatusSeeOther)
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
	a.store.Audit(s.User, a.clientIP(r), act, st.Server.Name+": "+detail)
	http.Redirect(w, r, "/s/"+strconv.Itoa(n)+"?msg="+urlq(msg), http.StatusSeeOther)
}

func (a *App) audit(w http.ResponseWriter, r *http.Request, s *Session) {
	a.render(w, "audit.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Lines": a.store.RecentAudit(200)})
}
