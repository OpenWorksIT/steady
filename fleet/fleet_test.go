// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestTOTPMatchesRFC6238(t *testing.T) {
	// RFC 6238 test secret "12345678901234567890", SHA1: 94287082 at 59 s, 07081804 at 1111111109 s
	secret := "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	for _, c := range []struct {
		at   int64
		want string
	}{{59, "287082"}, {1111111109, "081804"}, {1234567890, "005924"}} {
		got, err := totpAt(secret, c.at/30)
		if err != nil || got != c.want {
			t.Fatalf("totp at %d = %s %v, want %s", c.at, got, err, c.want)
		}
	}
}

func TestTOTPCheckWindowAndReplay(t *testing.T) {
	u := NewUser("tiaan", "a long enough password")
	now := time.Unix(1_800_000_000, 0)
	code, _ := totpAt(u.TOTP, now.Unix()/30)
	step := TOTPCheck(&u, code, now)
	if step == 0 {
		t.Fatal("current code refused")
	}
	u.LastStep = step
	if TOTPCheck(&u, code, now) != 0 {
		t.Fatal("a used code worked again")
	}
	old, _ := totpAt(u.TOTP, now.Unix()/30-3)
	if TOTPCheck(&u, old, now) != 0 {
		t.Fatal("a 90-second-old code worked")
	}
	if TOTPCheck(nil, code, now) != 0 || TOTPCheck(&u, "12345", now) != 0 {
		t.Fatal("bad input accepted")
	}
}

func TestPassword(t *testing.T) {
	u := NewUser("tiaan", "correct horse battery")
	if !PasswordOK(&u, "correct horse battery") || PasswordOK(&u, "wrong") || PasswordOK(nil, "x") {
		t.Fatal("password check wrong")
	}
}

func TestLimiter(t *testing.T) {
	l := NewLimiter()
	now := time.Now()
	for i := 0; i < failsPerIP; i++ {
		l.Fail("1.2.3.4", "user"+string(rune('a'+i)), now)
	}
	if !l.Blocked("1.2.3.4", "someone", now) {
		t.Fatal("address not blocked")
	}
	if l.Blocked("5.6.7.8", "someone", now) {
		t.Fatal("another address blocked")
	}
	if l.Blocked("1.2.3.4", "someone", now.Add(failWindow+time.Second)) {
		t.Fatal("block didn't expire")
	}
}

// a fake practice server
type fakeSteady struct {
	mu       sync.Mutex
	requests []string
	srv      *httptest.Server
}

func newFakeSteady(t *testing.T) *fakeSteady {
	f := &fakeSteady{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/steady/fleet" && r.Header.Get("X-Steady-Monitor") == "monitor-key-0123456789abcdef":
			json.NewEncoder(w).Encode(map[string]any{
				"practice": "VR Clinical Psychology", "health": map[string]any{"status": "good", "reasons": []any{}},
				"version": map[string]any{"code": "83f8776", "managed": true, "signed": true, "behind": 0},
				"host":    map[string]any{"disk": map[string]any{"total": 25e9, "used": 5e9}, "memory": map[string]any{"total": 2e9, "available": 1e9}, "backups": map[string]any{"newest": time.Now().Add(-5 * time.Hour).UTC().Format(time.RFC3339), "count": 3, "bytes": 1e6}},
				"counts":  map[string]any{"patients": 12, "staff": 4, "checkins7d": 60},
			})
		case r.URL.Path == "/api/steady/fleet/request" && r.Method == "POST" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
			var b map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			f.mu.Lock()
			f.requests = append(f.requests, b["action"])
			f.mu.Unlock()
			w.Write([]byte(`{"pending":"` + b["action"] + `"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func setup(t *testing.T) (*App, *httptest.Server, *fakeSteady, *User, string) {
	dir := t.TempDir()
	steady := newFakeSteady(t)
	store := NewStore(dir)
	servers := []Server{{Name: "VR Clinical Psychology", URL: strings.Replace(steady.srv.URL, "http://", "http://", 1), MonitorKey: "monitor-key-0123456789abcdef", FleetKey: "fleet-key-0123456789abcdefgh"}}
	if err := writeJSON(dir+"/servers.json", servers); err != nil {
		t.Fatal(err)
	}
	u := NewUser("tiaan", "a long enough password")
	store.SaveUsers([]User{u})
	poller := NewPoller(store)
	poller.PollAll(context.Background())
	app := NewApp(store, poller, false)
	app.insecureCookie = true
	site := httptest.NewServer(app.Routes())
	t.Cleanup(site.Close)
	return app, site, steady, &u, dir
}

func client() *http.Client {
	jar, _ := cookiejar.New(nil)
	return &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func body(t *testing.T, res *http.Response) string {
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	return string(b)
}

func TestSignInAndPages(t *testing.T) {
	_, site, steady, u, dir := setup(t)
	c := client()

	// signed out: pages go to the sign-in page
	res, _ := c.Get(site.URL + "/")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/login" {
		t.Fatalf("signed out: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = c.Get(site.URL + "/login")
	if csp := res.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Fatal("no CSP")
	}
	body(t, res)

	// wrong password, then a right password with a wrong code
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"tiaan"}, "password": {"nope"}, "code": {"000000"}})
	if res.StatusCode != 401 {
		t.Fatalf("wrong password: %d", res.StatusCode)
	}
	body(t, res)
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"tiaan"}, "password": {"a long enough password"}, "code": {"000000"}})
	if res.StatusCode != 401 {
		t.Fatalf("wrong code: %d", res.StatusCode)
	}
	body(t, res)

	// right password and code
	code, _ := totpAt(u.TOTP, time.Now().Unix()/30)
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"tiaan"}, "password": {"a long enough password"}, "code": {code}})
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/" {
		t.Fatalf("sign in: %d", res.StatusCode)
	}
	body(t, res)
	ck := res.Cookies()
	if len(ck) != 1 || !ck[0].HttpOnly || ck[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie: %+v", ck)
	}

	// the same code can't be used again (another browser)
	c2 := client()
	res, _ = c2.PostForm(site.URL+"/login", url.Values{"name": {"tiaan"}, "password": {"a long enough password"}, "code": {code}})
	if res.StatusCode != 401 {
		t.Fatalf("code reused: %d", res.StatusCode)
	}
	body(t, res)

	// the overview shows the server
	res, _ = c.Get(site.URL + "/")
	page := body(t, res)
	for _, want := range []string{"VR Clinical Psychology", "83f8776", "up to date", "20% of", "5 h ago", "60"} {
		if !strings.Contains(page, want) {
			t.Fatalf("overview lacks %q", want)
		}
	}

	// actions need the CSRF token, and update/restart the practice's name typed out
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"action": {"restart"}, "confirm": {"VR Clinical Psychology"}})
	if res.StatusCode != 403 {
		t.Fatalf("no csrf: %d", res.StatusCode)
	}
	body(t, res)
	res, _ = c.Get(site.URL + "/s/0")
	page = body(t, res)
	i := strings.Index(page, `name="csrf" value="`)
	csrf := page[i+len(`name="csrf" value="`):]
	csrf = csrf[:strings.Index(csrf, `"`)]
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"csrf": {csrf}, "action": {"restart"}, "confirm": {"wrong"}})
	body(t, res)
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"csrf": {csrf}, "action": {"restart"}, "confirm": {"VR Clinical Psychology"}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("restart: %d", res.StatusCode)
	}
	body(t, res)
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"csrf": {csrf}, "action": {"check"}})
	body(t, res)
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"csrf": {csrf}, "action": {"rm"}})
	if res.StatusCode != 400 {
		t.Fatalf("unknown action: %d", res.StatusCode)
	}
	body(t, res)
	steady.mu.Lock()
	got := strings.Join(steady.requests, ",")
	steady.mu.Unlock()
	if got != "restart,check" {
		t.Fatalf("requests sent: %q", got)
	}

	// the audit log has the sign-ins and actions
	b, _ := os.ReadFile(dir + "/audit.log")
	for _, want := range []string{"sign-in failed", "signed in", `"what":"restart"`, `"what":"check"`} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("audit lacks %s", want)
		}
	}

	// someone removed from users.json is signed out
	NewStore(dir).SaveUsers(nil)
	res, _ = c.Get(site.URL + "/")
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("removed user still in: %d", res.StatusCode)
	}
	body(t, res)
}

func TestTooManyTries(t *testing.T) {
	_, site, _, _, _ := setup(t)
	c := client()
	for i := 0; i < failsPerIP; i++ {
		res, _ := c.PostForm(site.URL+"/login", url.Values{"name": {"x"}, "password": {"y"}, "code": {"000000"}})
		body(t, res)
	}
	res, _ := c.PostForm(site.URL+"/login", url.Values{"name": {"tiaan"}, "password": {"a long enough password"}, "code": {"000000"}})
	if res.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("not limited: %d", res.StatusCode)
	}
	body(t, res)
}

func TestUnreachableServer(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	writeJSON(dir+"/servers.json", []Server{{Name: "Gone", URL: "http://127.0.0.1:1", MonitorKey: "monitor-key-0123456789abcdef"}})
	p := NewPoller(store)
	p.PollAll(context.Background())
	sts, _ := p.Snapshot()
	r := makeRow(0, sts[0], time.Now())
	if r.Level != "down" || r.Err == "" || r.CanAct {
		t.Fatalf("row: %+v", r)
	}
	if err := p.Request(context.Background(), sts[0].Server, "update"); err == nil || !strings.Contains(err.Error(), "only look") {
		t.Fatalf("request without a fleet key: %v", err)
	}
}

func TestServersMustUseHTTPS(t *testing.T) {
	if checkServer(Server{URL: "http://vr.steadyapp.co.za", MonitorKey: strings.Repeat("k", 30)}) == nil {
		t.Fatal("plain http accepted")
	}
	if checkServer(Server{URL: "https://vr.steadyapp.co.za", MonitorKey: "short"}) == nil {
		t.Fatal("short key accepted")
	}
}
