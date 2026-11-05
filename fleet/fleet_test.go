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
				"version":           map[string]any{"code": "83f8776", "managed": true, "signed": true, "behind": 0, "latest": map[string]any{"sha": "83f87760000", "release": "v1.0.2"}},
				"host":              map[string]any{"disk": map[string]any{"total": 25e9, "used": 5e9}, "memory": map[string]any{"total": 2e9, "available": 1e9}, "backups": map[string]any{"newest": time.Now().Add(-5 * time.Hour).UTC().Format(time.RFC3339), "count": 3, "bytes": 1e6}},
				"counts":            map[string]any{"patients": 12, "staff": 4, "checkins7d": 60, "olderConsent": 3, "deletionOverdue": 0, "staffWithoutTwoStep": 1},
				"operatorAgreement": map[string]any{"version": "1.0", "signed": true, "signedAt": "2026-11-03T08:00:00Z"},
				"audit": map[string]any{"at": time.Now().Add(-2 * time.Hour).UTC().Format(time.RFC3339), "code": "9d66cbe", "items": []any{
					map[string]any{"level": "fail", "section": "Firewall and listening ports", "text": "no firewall drops incoming connections <script>"},
					map[string]any{"level": "warn", "section": "SSH", "text": "X11 forwarding is on"},
					map[string]any{"level": "ok", "section": "Disk", "text": "disk 11% used"},
				}},
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
	// its version as a number: it runs the latest signed release (1.0.2), though it doesn't report versions yet
	for _, want := range []string{"VR Clinical Psychology", "<code>1.0.2</code>", "up to date", "20% of", "5 h ago", "60",
		"1 to fix, 1 to look at", "3 on an older consent statement, 1 staff without two-step sign-in"} {
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
	if !strings.Contains(page, "Operator agreement") || !strings.Contains(page, "signed, version 1.0, on 3 Nov 2026") {
		t.Fatalf("the detail page doesn't say the operator agreement is signed")
	}
	// the security and privacy check: what to fix first, what passed one click down, text escaped
	for _, want := range []string{"Security and privacy checks", "checked 2 h ago by code 9d66cbe", "no firewall drops incoming connections &lt;script&gt;",
		"X11 forwarding is on", "1 passed", "disk 11% used", "Patients on an older consent statement</dt><dd>3"} {
		if !strings.Contains(page, want) {
			t.Fatalf("detail page lacks %q", want)
		}
	}
	if strings.Contains(page, "<script>") {
		t.Fatal("a check's text wasn't escaped")
	}
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

func TestAnOpenTabStaysSignedIn(t *testing.T) {
	app, site, _, u, _ := setup(t)
	start := time.Now()
	clock := start
	app.now = func() time.Time { return clock }
	c := signIn(t, site, u, start)
	// a whole day with the tab open: only its /alive frame asks, once a minute
	for m := 1; m <= 24*60; m++ {
		clock = start.Add(time.Duration(m) * time.Minute)
		res, _ := c.Get(site.URL + "/alive")
		b := body(t, res)
		if res.StatusCode != 200 || res.Header.Get("Refresh") != "60" || !strings.Contains(b, "alive") {
			t.Fatalf("signed out after %d minutes with the tab open: %d %q", m, res.StatusCode, b)
		}
	}
	if res, _ := c.Get(site.URL + "/"); res.StatusCode != 200 {
		t.Fatalf("overview after a day: %d", res.StatusCode)
	}
	// every page carries the frame, and may frame only this site
	res, _ := c.Get(site.URL + "/todo")
	page := body(t, res)
	if !strings.Contains(page, `<iframe class="alive" src="/alive"`) || !strings.Contains(res.Header.Get("Content-Security-Policy"), "frame-src 'self'") ||
		!strings.Contains(res.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") || res.Header.Get("X-Frame-Options") != "DENY" {
		t.Fatal("no /alive frame, or the frame rules are wrong")
	}
	res, _ = c.Get(site.URL + "/alive")
	body(t, res)
	if !strings.Contains(res.Header.Get("Content-Security-Policy"), "frame-ancestors 'self'") || res.Header.Get("X-Frame-Options") != "SAMEORIGIN" {
		t.Fatal("/alive may be framed by other sites")
	}
}

func TestAClosedTabSignsOut(t *testing.T) {
	app, site, _, u, _ := setup(t)
	start := time.Now()
	clock := start
	app.now = func() time.Time { return clock }
	c := signIn(t, site, u, start)
	// the tab closes: nothing asks for 11 minutes
	clock = start.Add(11 * time.Minute)
	res, _ := c.Get(site.URL + "/alive")
	if b := body(t, res); res.Header.Get("Refresh") != "" || !strings.Contains(b, "signed out") {
		t.Fatalf("still alive after the tab closed: %q", b)
	}
	if res, _ := c.Get(site.URL + "/"); res.StatusCode != http.StatusSeeOther {
		t.Fatalf("still signed in after the tab closed: %d", res.StatusCode)
	}
	// and signed out, /alive keeps nobody in
	res, _ = client().Get(site.URL + "/alive")
	if res.Header.Get("Refresh") != "" {
		t.Fatal("/alive keeps reloading for nobody")
	}
	body(t, res)
}

func TestTheSignInCookieIsForTheBrowserSessionOnly(t *testing.T) {
	_, site, _, u, _ := setup(t)
	c := client()
	code, _ := totpAt(u.TOTP, time.Now().Unix()/30)
	res, _ := c.PostForm(site.URL+"/login", url.Values{"name": {u.Name}, "password": {"a long enough password"}, "code": {code}})
	body(t, res)
	sc := res.Header.Get("Set-Cookie")
	if !strings.HasPrefix(sc, cookieName+"=") || strings.Contains(sc, "Max-Age") || strings.Contains(sc, "Expires") {
		t.Fatalf("the cookie outlives the browser: %s", sc)
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

func TestCommunityCountsOnly(t *testing.T) {
	var gotKey string
	forum := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.Header.Get("Api-Key")
		if r.URL.Path != "/about.json" || gotKey != strings.Repeat("s", 40) {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		w.Write([]byte(`{"about":{"title":"Steady Community","admins":[{"username":"kempie"}],"stats":{"users_count":4,"active_users_7_days":3,"participating_users_7_days":2,"topics_count":12,"topics_7_days":3,"posts_count":80,"posts_7_days":9,"secret_title":"A private topic"}}}`))
	}))
	defer forum.Close()
	dir := t.TempDir()
	s := NewStore(dir)
	if c, err := s.Community(); c != nil || err != nil {
		t.Fatal("no community.json should mean no forum")
	}
	p := NewPoller(s)
	writeJSON(dir+"/community.json", Community{URL: "http://x", StatsKey: strings.Repeat("s", 40)})
	if st := p.fetchCommunity(context.Background()); st == nil || !strings.Contains(st.Err, "https") {
		t.Fatalf("http forum: %+v", st)
	}
	tls := httptest.NewTLSServer(forum.Config.Handler)
	defer tls.Close()
	writeJSON(dir+"/community.json", Community{URL: tls.URL, StatsKey: strings.Repeat("s", 40)})
	p.client = tls.Client()
	p.client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	p.PollCommunity(context.Background())
	st := p.CommunitySnapshot()
	if st.Err != "" || st.Counts["users_count"] != 4 || len(st.Counts) != 7 {
		t.Fatalf("counts: %+v", st)
	}
	v := makeCommunity(st, time.Now())
	if v.Members != "4" || v.Topics != "12 (3 this week)" || v.Posts != "80 (9 this week)" {
		t.Fatalf("view: %+v", v)
	}
	if b, _ := json.Marshal(st); strings.Contains(string(b), "private topic") || strings.Contains(string(b), "kempie") {
		t.Fatal("kept more than numbers")
	}
	// a revoked key: the forum sends people to sign in
	writeJSON(dir+"/community.json", Community{URL: tls.URL, StatsKey: strings.Repeat("r", 40)})
	p.PollCommunity(context.Background())
	if st := p.CommunitySnapshot(); !strings.Contains(st.Err, "wasn't accepted") {
		t.Fatalf("revoked key: %+v", st)
	}
}

func TestOverviewShowsTheForum(t *testing.T) {
	app, site, _, u, _ := setup(t)
	app.poller.community = &CommunityStatus{URL: "https://community.steadyapp.co.za", At: time.Now(), Counts: map[string]float64{"users_count": 4, "topics_count": 12, "topics_7_days": 3}}
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/")
	page := body(t, res)
	for _, want := range []string{"Community forum", "community.steadyapp.co.za", "12 (3 this week)"} {
		if !strings.Contains(page, want) {
			t.Fatalf("overview lacks %q", want)
		}
	}
}

func TestFormsOnlyFromThisSite(t *testing.T) {
	_, site, steady, u, _ := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/s/0")
	page := body(t, res)
	i := strings.Index(page, `name="csrf" value="`)
	csrf := page[i+len(`name="csrf" value="`):]
	csrf = csrf[:strings.Index(csrf, `"`)]
	post := func(site_ string) int {
		req, _ := http.NewRequest("POST", site.URL+"/s/0/action", strings.NewReader(url.Values{"csrf": {csrf}, "action": {"check"}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if site_ != "" {
			req.Header.Set("Sec-Fetch-Site", site_)
		}
		res, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body(t, res)
		return res.StatusCode
	}
	// a sibling subdomain (same-site) or another site: refused even with the right token
	for _, s := range []string{"same-site", "cross-site"} {
		if got := post(s); got != 403 {
			t.Fatalf("%s: %d", s, got)
		}
	}
	for _, s := range []string{"same-origin", ""} {
		if got := post(s); got != http.StatusSeeOther {
			t.Fatalf("%q: %d", s, got)
		}
	}
	steady.mu.Lock()
	got := strings.Join(steady.requests, ",")
	steady.mu.Unlock()
	if got != "check,check" {
		t.Fatalf("requests sent: %q", got)
	}
}

func TestSignInQueueGivesUp(t *testing.T) {
	app, _, _, _, _ := setup(t)
	app.hashWait = 50 * time.Millisecond
	app.hashing <- struct{}{}
	app.hashing <- struct{}{}
	defer func() { <-app.hashing; <-app.hashing }()
	req := httptest.NewRequest("POST", "/login", strings.NewReader("name=jane&password=x&code=1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	start := time.Now()
	app.Routes().ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable || time.Since(start) > 2*time.Second {
		t.Fatalf("busy: %d after %v", w.Code, time.Since(start))
	}
}

func TestAuditSummary(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	// none yet (a server older than 1.0.6, or the service not installed)
	if a := makeAudit(map[string]any{}, now); a.Have || a.Summary != "no check yet" || a.PrivacyWarn {
		t.Fatalf("no audit: %+v", a)
	}
	at := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	ok := map[string]any{"level": "ok", "section": "Disk", "text": "fine"}
	a := makeAudit(map[string]any{"audit": map[string]any{"at": at(time.Hour), "items": []any{ok}}}, now)
	if a.Summary != "all clear" || a.SummaryClass != "good" || a.Oks != 1 || a.Stale {
		t.Fatalf("clear: %+v", a)
	}
	// a check that stopped running isn't "all clear"
	a = makeAudit(map[string]any{"audit": map[string]any{"at": at(20 * time.Hour), "items": []any{ok}}}, now)
	if !a.Stale || a.SummaryClass != "warn" || !strings.Contains(a.Summary, "stopped running") {
		t.Fatalf("stale: %+v", a)
	}
	// failures first, then warnings; junk ignored
	a = makeAudit(map[string]any{"audit": map[string]any{"at": at(time.Hour), "items": []any{
		map[string]any{"level": "warn", "text": "w"}, "junk", map[string]any{"level": "fail", "text": "f"}, map[string]any{"level": "other"}}},
		"counts": map[string]any{"deletionOverdue": 2.0}}, now)
	if a.Fails != 1 || a.Warns != 1 || a.Problems[0].Text != "f" || a.SummaryClass != "bad" || !a.PrivacyWarn || a.PrivacyNote != "2 deletion past 25 days" {
		t.Fatalf("problems: %+v", a)
	}
}

func TestChecksPageBySeverity(t *testing.T) {
	_, site, _, u, _ := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/checks")
	page := body(t, res)
	fix, look := strings.Index(page, "To fix"), strings.Index(page, "To look at")
	if fix < 0 || look < fix {
		t.Fatal("not ordered by severity")
	}
	fixPart, lookPart := page[fix:look], page[look:]
	for _, want := range []string{"no firewall drops incoming connections &lt;script&gt;"} {
		if !strings.Contains(fixPart, want) {
			t.Fatalf("to fix lacks %q", want)
		}
	}
	for _, want := range []string{"X11 forwarding is on", "3 patient(s) haven&#39;t yet agreed to the current consent statement", "1 staff member(s) without two-step sign-in"} {
		if !strings.Contains(lookPart, want) {
			t.Fatalf("to look at lacks %q", want)
		}
	}
	if !strings.Contains(page, `aria-label="1 to fix, 3 to look at, 1 passed"`) || !strings.Contains(page, `href="/checks"`) {
		t.Fatal("no bar or no link to the page")
	}
	if strings.Contains(page, "<script>") {
		t.Fatal("not escaped")
	}
}

func TestMakeChecks(t *testing.T) {
	now := time.Now()
	down := &Status{Server: Server{Name: "Down"}, At: now, Err: "can't reach the server: refused"}
	none := &Status{Server: Server{Name: "Old"}, At: now, Data: map[string]any{"counts": map[string]any{"deletionOverdue": 2.0}}}
	stale := &Status{Server: Server{Name: "Stale"}, At: now, Data: map[string]any{"audit": map[string]any{"at": now.Add(-30 * time.Hour).Format(time.RFC3339), "items": []any{
		map[string]any{"level": "ok", "text": "fine"}}}}}
	p := makeChecks([]*Status{down, none, stale}, now)
	if len(p.Fix) != 2 || p.Fix[0].Server != "Down" || !strings.Contains(p.Fix[1].Text, "2 deletion request(s)") {
		t.Fatalf("fix: %+v", p.Fix)
	}
	if len(p.Look) != 2 || !strings.Contains(p.Look[0].Text, "no security and privacy check") || !strings.Contains(p.Look[1].Text, "has stopped") {
		t.Fatalf("look: %+v", p.Look)
	}
	if p.Servers[2].Passed != 1 || p.Servers[2].SummaryClass != "warn" || p.Servers[0].SummaryClass != "bad" {
		t.Fatalf("servers: %+v", p.Servers)
	}
	if p.Servers[1].FixW != "50.00" || p.Servers[1].LookW != "50.00" {
		t.Fatalf("bar: %+v", p.Servers[1])
	}
}

func TestVersionText(t *testing.T) {
	ver := func(v map[string]any) string { return versionText(map[string]any{"version": v}) }
	cases := []struct {
		v    map[string]any
		want string
	}{
		{map[string]any{"code": "48e2af3", "current": map[string]any{"version": "1.0.5"}}, "1.0.5"},
		{map[string]any{"code": "b489d65", "current": map[string]any{"version": "1.1.0 test 23"}}, "1.1.0 test 23"},
		// a server from before versions: the release's number when it runs the latest release
		{map[string]any{"code": "48e2af3", "latest": map[string]any{"sha": "48e2af3aaaa", "release": "v1.0.5"}}, "1.0.5"},
		// ...and its code when it doesn't
		{map[string]any{"code": "6bc38d5", "latest": map[string]any{"sha": "48e2af3aaaa", "release": "v1.0.5"}}, "6bc38d5"},
		{map[string]any{}, "?"},
	}
	for _, c := range cases {
		if got := ver(c.v); got != c.want {
			t.Errorf("%v: %q, want %q", c.v, got, c.want)
		}
	}
	if releaseText(map[string]any{"version": map[string]any{"latest": map[string]any{"release": "v1.0.5"}}}) != "1.0.5" {
		t.Error("release text")
	}
}
