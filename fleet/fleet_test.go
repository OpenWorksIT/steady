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
	u := NewUser("jane", "a long enough password")
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
	u := NewUser("jane", "correct horse battery")
	if !PasswordOK(&u, "correct horse battery") || PasswordOK(&u, "wrong") || PasswordOK(nil, "x") {
		t.Fatal("password check wrong")
	}
}

func TestLimiter(t *testing.T) {
	l := NewLimiter()
	now := time.Now()
	k := addrKey("1.2.3.4")
	for i := 0; i < failsPerIP; i++ {
		if !l.Take(k, failsPerIP, now.Add(time.Duration(i)*time.Millisecond)) {
			t.Fatal("refused too early")
		}
	}
	if l.Take(k, failsPerIP, now) || !l.Blocked(k, failsPerIP, now) {
		t.Fatal("address not blocked")
	}
	if l.Blocked(addrKey("5.6.7.8"), failsPerIP, now) {
		t.Fatal("another address blocked")
	}
	if l.Blocked(k, failsPerIP, now.Add(failWindow+time.Second)) {
		t.Fatal("block didn't expire")
	}
	// a sign-in that worked gives its slot back
	l.Give(k, now)
	if l.Blocked(k, failsPerIP, now.Add(10*time.Millisecond)) {
		t.Fatal("slot not given back")
	}
	// one IPv6 customer can't dodge the limit by changing the last 64 bits
	if addrKey("2001:db8:1:2::1") != addrKey("2001:db8:1:2:ffff::9") || addrKey("2001:db8:1:2::1") == addrKey("2001:db8:1:3::1") {
		t.Fatal("IPv6 not grouped by /64")
	}
}

func TestNames(t *testing.T) {
	for _, ok := range []string{"jane", "j.doe", "ops-1", "a_b"} {
		if validName(ok) != nil {
			t.Fatalf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "Jane", "jane doe", "jаne" /* Cyrillic а */, strings.Repeat("a", 41), "x<y"} {
		if validName(bad) == nil {
			t.Fatalf("%q accepted", bad)
		}
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
		case r.URL.Path == "/api/steady/fleet" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
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
	servers := []Server{{Name: "VR Clinical Psychology", URL: steady.srv.URL, FleetKey: "fleet-key-0123456789abcdefgh"}}
	if err := writeJSON(dir+"/servers.json", servers); err != nil {
		t.Fatal(err)
	}
	u := NewUser("jane", "a long enough password")
	store.SaveUsers([]User{u})
	poller := NewPoller(store)
	poller.PollAll(context.Background())
	app := NewApp(store, poller, "")
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
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"jane"}, "password": {"nope"}, "code": {"000000"}})
	if res.StatusCode != 401 {
		t.Fatalf("wrong password: %d", res.StatusCode)
	}
	body(t, res)
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"jane"}, "password": {"a long enough password"}, "code": {"000000"}})
	if res.StatusCode != 401 {
		t.Fatalf("wrong code: %d", res.StatusCode)
	}
	body(t, res)

	// right password and code
	code, _ := totpAt(u.TOTP, time.Now().Unix()/30)
	res, _ = c.PostForm(site.URL+"/login", url.Values{"name": {"jane"}, "password": {"a long enough password"}, "code": {code}})
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
	res, _ = c2.PostForm(site.URL+"/login", url.Values{"name": {"jane"}, "password": {"a long enough password"}, "code": {code}})
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
	res, _ := c.PostForm(site.URL+"/login", url.Values{"name": {"jane"}, "password": {"a long enough password"}, "code": {"000000"}})
	if res.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("not limited: %d", res.StatusCode)
	}
	body(t, res)
}

func TestUnreachableServer(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	writeJSON(dir+"/servers.json", []Server{{Name: "Gone", URL: "http://127.0.0.1:1", FleetKey: "fleet-key-0123456789abcdefgh"}})
	p := NewPoller(store)
	p.PollAll(context.Background())
	sts, _ := p.Snapshot()
	r := makeRow(0, sts[0], time.Now())
	if r.Level != "down" || r.Err == "" || r.CanAct {
		t.Fatalf("row: %+v", r)
	}
	if err := p.Request(context.Background(), sts[0].Server, "update"); err == nil {
		t.Fatal("request to an unreachable server worked")
	}
}

func TestServersMustUseHTTPS(t *testing.T) {
	key := strings.Repeat("k", 30)
	for _, bad := range []string{"http://vr.steadyapp.co.za", "http://127.0.0.1.evil.example", "http://127.0.0.1@evil.example"} {
		if checkServer(Server{URL: bad, FleetKey: key}) == nil {
			t.Fatalf("%s accepted", bad)
		}
	}
	if checkServer(Server{URL: "http://127.0.0.1:8090", FleetKey: key}) != nil || checkServer(Server{URL: "https://vr.steadyapp.co.za", FleetKey: key}) != nil {
		t.Fatal("good server refused")
	}
	if checkServer(Server{URL: "https://vr.steadyapp.co.za", FleetKey: "short"}) == nil {
		t.Fatal("short key accepted")
	}
}

func signIn(t *testing.T, site *httptest.Server, u *User, at time.Time) *http.Client {
	c := client()
	code, _ := totpAt(u.TOTP, at.Unix()/30)
	res, _ := c.PostForm(site.URL+"/login", url.Values{"name": {u.Name}, "password": {"a long enough password"}, "code": {code}})
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("sign in: %d %s", res.StatusCode, body(t, res))
	}
	body(t, res)
	return c
}

func TestWrongGuessesCantLockSomeoneOut(t *testing.T) {
	app, site, _, u, _ := setup(t)
	// many addresses guessing passwords for the name: the person can still sign in
	for i := 0; i < failsPerUser*2; i++ {
		req := httptest.NewRequest("POST", "/login", strings.NewReader(url.Values{"name": {"jane"}, "password": {"guess"}, "code": {"000000"}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.RemoteAddr = "10.0." + string(rune('0'+i%10)) + "." + string(rune('1'+i/10)) + ":5000"
		w := httptest.NewRecorder()
		app.Routes().ServeHTTP(w, req)
		if w.Code != 401 {
			t.Fatalf("guess %d: %d", i, w.Code)
		}
	}
	signIn(t, site, u, time.Now())
}

func TestWrongCodesLockTheName(t *testing.T) {
	app, _, _, _, _ := setup(t)
	try := func(ip string) int {
		req := httptest.NewRequest("POST", "/login", strings.NewReader(url.Values{"name": {"jane"}, "password": {"a long enough password"}, "code": {"000000"}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.RemoteAddr = ip + ":5000"
		w := httptest.NewRecorder()
		app.Routes().ServeHTTP(w, req)
		return w.Code
	}
	// someone with the password but not the phone, from many addresses
	for i := 0; i < failsPerUser; i++ {
		if c := try("10.1.0." + string(rune('a'+i))); c != 401 && c != 429 {
			t.Fatalf("try %d: %d", i, c)
		}
	}
	if c := try("10.2.0.1"); c != http.StatusTooManyRequests {
		t.Fatalf("name not locked after wrong codes: %d", c)
	}
}

func TestForgedForwardedForIsIgnored(t *testing.T) {
	app, _, _, _, _ := setup(t)
	// no trusted proxy: a visitor can't pick a new address per try
	for i := 0; i < failsPerIP+1; i++ {
		req := httptest.NewRequest("POST", "/login", strings.NewReader("name=x&password=y&code=000000"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("X-Forwarded-For", "198.51.100."+string(rune('1'+i)))
		req.RemoteAddr = "203.0.113.9:4000"
		w := httptest.NewRecorder()
		app.Routes().ServeHTTP(w, req)
		if i == failsPerIP && w.Code != http.StatusTooManyRequests {
			t.Fatalf("X-Forwarded-For believed: %d", w.Code)
		}
	}
	// with Caddy as the trusted proxy, its X-Forwarded-For is the visitor
	app.proxy = "203.0.113.9"
	req := httptest.NewRequest("GET", "/login", nil)
	req.RemoteAddr = "203.0.113.9:4000"
	req.Header.Set("X-Forwarded-For", "evil, 198.51.100.7")
	if ip := app.clientIP(req); ip != "198.51.100.7" {
		t.Fatalf("proxy's visitor: %s", ip)
	}
	req.RemoteAddr = "192.0.2.1:4000"
	if ip := app.clientIP(req); ip != "192.0.2.1" {
		t.Fatalf("not the proxy, but X-Forwarded-For believed: %s", ip)
	}
}

func TestBigFormsRefused(t *testing.T) {
	app, _, _, _, dir := setup(t)
	req := httptest.NewRequest("POST", "/login", strings.NewReader("name="+strings.Repeat("a", 100000)+"&password=y&code=1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	app.Routes().ServeHTTP(w, req)
	if w.Code != 401 {
		t.Fatalf("big form: %d", w.Code)
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	if len(b) > 1000 {
		t.Fatalf("audit log grew by %d bytes", len(b))
	}
}

func TestMessagesCantComeFromALink(t *testing.T) {
	_, site, _, u, _ := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/s/0?msg=Call+0800+for+help")
	if strings.Contains(body(t, res), "0800") {
		t.Fatal("?msg shown on the page")
	}
}

func TestAutoRefreshDoesntKeepYouIn(t *testing.T) {
	app, site, _, u, _ := setup(t)
	start := time.Now()
	clock := start
	app.now = func() time.Time { return clock }
	c := signIn(t, site, u, start)
	// the page refreshes itself every minute for 40 minutes
	for m := 1; m <= 40; m++ {
		clock = start.Add(time.Duration(m) * time.Minute)
		res, _ := c.Get(site.URL + "/?auto=1")
		body(t, res)
		if m > 31 && res.StatusCode != http.StatusSeeOther {
			t.Fatalf("still signed in after %d idle minutes", m)
		}
	}
}

func TestRedirectsArentFollowed(t *testing.T) {
	var leaked string
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = r.Header.Get("X-Steady-Fleet") }))
	defer elsewhere.Close()
	redir := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL+r.URL.Path, http.StatusTemporaryRedirect)
	}))
	defer redir.Close()
	dir := t.TempDir()
	writeJSON(dir+"/servers.json", []Server{{Name: "Moved", URL: redir.URL, FleetKey: "fleet-key-0123456789abcdefgh"}})
	p := NewPoller(NewStore(dir))
	p.PollAll(context.Background())
	sts, _ := p.Snapshot()
	p.Request(context.Background(), sts[0].Server, "check")
	if leaked != "" {
		t.Fatal("the fleet key followed a redirect")
	}
	if !strings.Contains(sts[0].Err, "redirect") {
		t.Fatalf("error: %q", sts[0].Err)
	}
}

func TestUsersFileStaysWhole(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.UpdateUsers(func(all []User) ([]User, error) {
				return append(all, User{Name: "u" + string(rune('a'+i))}), nil
			})
		}(i)
	}
	wg.Wait()
	all, err := s.Users()
	if err != nil || len(all) != 20 {
		t.Fatalf("users after parallel changes: %d %v", len(all), err)
	}
	fi, _ := os.Stat(dir + "/users.json")
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("users.json mode %v", fi.Mode().Perm())
	}
}
