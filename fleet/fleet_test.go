// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"fmt"
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
	noAudit  map[string]any // when set: no results, and this as the check's timer (host.auditService)
	comm     map[string]any // when set: the server's community block
	commSet  []map[string]any
	commOld  bool // Steady 1.2.0: takes the fleet view's setting but still says off
}

func newFakeSteady(t *testing.T) *fakeSteady {
	f := &fakeSteady{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/steady/fleet" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
			f.mu.Lock()
			noAudit := f.noAudit
			f.mu.Unlock()
			d := map[string]any{
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
			}
			if noAudit != nil {
				delete(d, "audit")
				d["host"].(map[string]any)["auditService"] = noAudit
			}
			f.mu.Lock()
			if f.comm != nil {
				d["community"] = f.comm
			}
			f.mu.Unlock()
			json.NewEncoder(w).Encode(d)
		case r.URL.Path == "/api/steady/fleet/request" && r.Method == "POST" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
			var b map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			f.mu.Lock()
			f.requests = append(f.requests, b["action"])
			f.mu.Unlock()
			w.Write([]byte(`{"pending":"` + b["action"] + `"}`))
		case r.URL.Path == "/api/steady/fleet/community" && r.Method == "POST" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
			var b map[string]any
			json.NewDecoder(r.Body).Decode(&b)
			f.mu.Lock()
			f.commSet = append(f.commSet, b)
			if b["on"] == true && f.commOld {
				// stored, but 1.2.0 couldn't read it
			} else if b["on"] == true {
				if f.comm == nil {
					f.comm = map[string]any{"members": []any{}}
				}
				f.comm["on"], f.comm["fleet"] = true, true
			} else if f.comm != nil {
				f.comm["on"] = false
			}
			f.mu.Unlock()
			w.Write([]byte(`{"on":` + fmt.Sprint(b["on"] == true) + `}`))
		case r.URL.Path == "/api/steady/fleet/reset" && r.Method == "POST" && r.Header.Get("X-Steady-Fleet") == "fleet-key-0123456789abcdefgh":
			var b map[string]any
			json.NewDecoder(r.Body).Decode(&b)
			f.mu.Lock()
			f.requests = append(f.requests, fmt.Sprintf("reset %v %v", b["email"], b["twoStep"]))
			f.mu.Unlock()
			if b["email"] == "pat@example.org" {
				w.WriteHeader(400)
				w.Write([]byte(`{"message":"Patients' passwords are reset by their psychologist, or with the code Steady emails them."}`))
				return
			}
			w.Write([]byte(`{"temporaryPassword":"Tmp-4821-quiet-otter","emailedTo":"t***@example.org","twoStepCleared":` + fmt.Sprint(b["twoStep"] == true) + `,"account":{"name":"Dr Two","role":"clinician"}}`))
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
	app, site, steady, u, dir := setup(t)
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

	// the website changes no server: the old action form is gone
	res, _ = c.PostForm(site.URL+"/s/0/action", url.Values{"action": {"restart"}, "confirm": {"VR Clinical Psychology"}})
	if res.StatusCode != 404 && res.StatusCode != 405 {
		t.Fatalf("a web action: %d", res.StatusCode)
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
	// jane (added before roles: a dev) sees the commands to run over SSH, not buttons
	if !strings.Contains(page, "sudo /opt/steady-ops/fleet/fleet.sh update 127.0.0.1") || strings.Contains(page, `action="/s/0/action"`) {
		t.Fatal("the dev's server page lacks the SSH commands, or still has the buttons")
	}
	body(t, res)
	// changes happen over SSH (fleet.sh): a restart only once its short name is typed
	t.Setenv("FLEET_ACTOR", "tiaan")
	var out strings.Builder
	if err := serverAction(app.store, "restart", []string{"127.0.0.1"}, strings.NewReader("wrong\n"), &out); err == nil || !strings.Contains(err.Error(), "not confirmed") {
		t.Fatalf("restart without confirming: %v", err)
	}
	if err := serverAction(app.store, "restart", []string{"127.0.0.1"}, strings.NewReader("127.0.0.1\n"), &out); err != nil {
		t.Fatal(err)
	}
	if err := serverAction(app.store, "check", []string{"VR Clinical Psychology"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	if err := serverAction(app.store, "update", []string{"nowhere"}, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "fleet servers") {
		t.Fatalf("an unknown server: %v", err)
	}
	steady.mu.Lock()
	got := strings.Join(steady.requests, ",")
	steady.mu.Unlock()
	if got != "restart,check" {
		t.Fatalf("requests sent: %q", got)
	}

	// the audit log has the sign-ins and actions
	b, _ := os.ReadFile(dir + "/audit.log")
	for _, want := range []string{"sign-in failed", "signed in", `"what":"restart"`, `"what":"check"`, `"who":"tiaan (ssh)"`} {
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
		if r.URL.Path != "/about.json" || gotKey != strings.Repeat("5a", 32) {
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
	// the key alone: not with its label, not cut short
	for _, bad := range []string{"DISCOURSE_STATS_KEY=" + strings.Repeat("5a", 32), strings.Repeat("5a", 31), strings.Repeat("ZZ", 32)} {
		writeJSON(dir+"/community.json", Community{URL: "https://community.example.org", StatsKey: bad})
		if _, err := s.Community(); err == nil || !strings.Contains(err.Error(), "statsKey must be the forum key alone") {
			t.Fatalf("%.24s...: %v", bad, err)
		}
	}
	writeJSON(dir+"/community.json", Community{URL: "http://x", StatsKey: strings.Repeat("5a", 32)})
	if st := p.fetchCommunity(context.Background()); st == nil || !strings.Contains(st.Err, "https") {
		t.Fatalf("http forum: %+v", st)
	}
	tls := httptest.NewTLSServer(forum.Config.Handler)
	defer tls.Close()
	writeJSON(dir+"/community.json", Community{URL: tls.URL, StatsKey: strings.Repeat("5a", 32)})
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
	writeJSON(dir+"/community.json", Community{URL: tls.URL, StatsKey: strings.Repeat("e0", 32)})
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
	res, _ := c.Get(site.URL + "/todo")
	page := body(t, res)
	i := strings.Index(page, `name="csrf" value="`)
	csrf := page[i+len(`name="csrf" value="`):]
	csrf = csrf[:strings.Index(csrf, `"`)]
	post := func(site_ string) int {
		form := url.Values{"csrf": {csrf}, "title": {"Check the backups"}, "area": {"OpenWorks"}, "priority": {"soon"}, "status": {"todo"}}
		req, _ := http.NewRequest("POST", site.URL+"/todo", strings.NewReader(form.Encode()))
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
	_ = steady
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
	// none from a server that doesn't say why: a red flag, with how to set it up
	if a := makeAudit(map[string]any{}, now); a.Have || a.Summary != "check not running" || a.SummaryClass != "bad" || !strings.Contains(a.Fix, "install.sh") || a.PrivacyWarn {
		t.Fatalf("no audit: %+v", a)
	}
	at := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	ok := map[string]any{"level": "ok", "section": "Disk", "text": "fine"}
	a := makeAudit(map[string]any{"audit": map[string]any{"at": at(time.Hour), "items": []any{ok}}}, now)
	if a.Summary != "all clear" || a.SummaryClass != "good" || a.Oks != 1 || a.Stale {
		t.Fatalf("clear: %+v", a)
	}
	// a check that stopped running isn't "all clear": it's a red flag
	a = makeAudit(map[string]any{"audit": map[string]any{"at": at(20 * time.Hour), "items": []any{ok}}}, now)
	if !a.Stale || a.SummaryClass != "bad" || a.Summary != "check not running" || !strings.Contains(a.Down, "20 h ago and has stopped") {
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
	// installed and waiting for its first run: worth a look, not a red flag
	waiting := &Status{Server: Server{Name: "New"}, At: now, Data: map[string]any{"host": map[string]any{"auditService": map[string]any{
		"installed": true, "enabled": true, "state": "inactive", "result": "success", "timer": "active"}}}}
	p := makeChecks([]*Status{down, none, stale, waiting}, nil, now)
	if len(p.Fix) != 4 || p.Fix[0].Server != "Down" || !strings.Contains(p.Fix[1].Text, "no check from this server") ||
		!strings.Contains(p.Fix[2].Text, "2 deletion request(s)") || !strings.Contains(p.Fix[3].Text, "has stopped") {
		t.Fatalf("fix: %+v", p.Fix)
	}
	if len(p.Look) != 1 || p.Look[0].Server != "New" || !strings.Contains(p.Look[0].Text, "waits for its first run") {
		t.Fatalf("look: %+v", p.Look)
	}
	if p.Servers[2].Passed != 1 || p.Servers[2].SummaryClass != "bad" || p.Servers[0].SummaryClass != "bad" || p.Servers[3].SummaryClass != "warn" {
		t.Fatalf("servers: %+v", p.Servers)
	}
	if p.Servers[1].FixW != "100.00" || p.Servers[1].LookW != "0.00" {
		t.Fatalf("bar: %+v", p.Servers[1])
	}
}

// What a server's stats step reports about its check (host.auditService) turns into a red flag
// that says why, or into nothing while the check is fine or under way.
func TestAuditDown(t *testing.T) {
	now := time.Date(2026, 11, 5, 18, 0, 0, 0, time.UTC)
	fresh := map[string]any{"at": now.Add(-time.Hour).Format(time.RFC3339), "items": []any{map[string]any{"level": "ok", "text": "fine"}}}
	svc := func(kv ...any) map[string]any {
		m := map[string]any{"installed": true, "enabled": true, "state": "inactive", "result": "success", "exitStatus": 0.0,
			"lastRun": now.Add(-time.Hour).Format(time.RFC3339), "timer": "active", "nextRun": now.Add(5 * time.Hour).Format(time.RFC3339)}
		for i := 0; i+1 < len(kv); i += 2 {
			m[kv[i].(string)] = kv[i+1]
		}
		return m
	}
	cases := []struct {
		name    string
		audit   any
		svc     map[string]any
		down    string // in the reason; "" = not flagged
		summary string
	}{
		{"fine", fresh, svc(), "", "all clear"},
		{"not installed", nil, svc("installed", false, "state", "", "result", "", "timer", ""), "isn't installed on this server: cd /opt/steady/deploy && sudo ./ctl/install.sh", "check not running"},
		{"timer off", fresh, svc("enabled", false, "timer", "inactive"), "timer is switched off", "check not running"},
		{"failed", fresh, svc("state", "failed", "result", "exit-code", "exitStatus", 2.0), "the last check failed (exit-code, exit 2, 1 h ago): sudo journalctl -u steady-audit", "check not running"},
		{"failed, running again", fresh, svc("state", "activating", "result", "exit-code"), "", "all clear"},
		{"first one running", nil, svc("state", "activating", "lastRun", ""), "", "first check running"},
		{"ran, results unread", nil, svc(), "can't read its results", "check not running"},
		{"waiting for its first run", nil, svc("lastRun", ""), "", "no check yet"},
		{"systemctl can't answer, results fresh", fresh, svc("state", "", "result", "", "timer", ""), "", "all clear"},
		{"stale, timer says fine", map[string]any{"at": now.Add(-14 * time.Hour).Format(time.RFC3339), "items": []any{}}, svc(), "has stopped", "check not running"},
	}
	for _, c := range cases {
		d := map[string]any{"host": map[string]any{"auditService": c.svc}}
		if c.audit != nil {
			d["audit"] = c.audit
		}
		a := makeAudit(d, now)
		if (c.down == "") != (a.Down == "") || !strings.Contains(a.DownText(), c.down) || a.Summary != c.summary {
			t.Errorf("%s: down %q, summary %q", c.name, a.DownText(), a.Summary)
		}
		if c.down != "" && a.SummaryClass != "bad" {
			t.Errorf("%s: not red: %s", c.name, a.SummaryClass)
		}
	}
	if a := makeAudit(map[string]any{"audit": fresh, "host": map[string]any{"auditService": svc()}}, now); a.NextRun != "in 5 h" {
		t.Errorf("next run: %q", a.NextRun)
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

// A server whose check isn't installed: red on the overview (with a count at the top), and the
// server's page says why and what to run there.
func TestCheckNotRunningPages(t *testing.T) {
	app, site, steady, u, _ := setup(t)
	steady.mu.Lock()
	steady.noAudit = map[string]any{"installed": false, "enabled": false, "state": "", "result": "", "timer": ""}
	steady.mu.Unlock()
	app.poller.PollAll(context.Background())
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/")
	page := body(t, res)
	for _, want := range []string{`id="code"`, `<strong>Fleet view</strong></td><td><code>1.1.1 (code 8272cc124f7a)</code>`, `1 without a running security check`, `class="check bad"`, `title="the check isn&#39;t installed on this server: cd /opt/steady/deploy &amp;&amp; sudo ./ctl/install.sh"`, `>check not running</a>`} {
		if !strings.Contains(page, want) {
			t.Fatalf("overview lacks %q", want)
		}
	}
	res, _ = c.Get(site.URL + "/s/0")
	page = body(t, res)
	for _, want := range []string{`Not running: the check isn&#39;t installed on this server.`, `<code>cd /opt/steady/deploy &amp;&amp; sudo ./ctl/install.sh</code>`} {
		if !strings.Contains(page, want) {
			t.Fatalf("server page lacks %q", want)
		}
	}
	res, _ = c.Get(site.URL + "/checks")
	page = body(t, res)
	if fix := strings.Index(page, "To fix"); fix < 0 || !strings.Contains(page[fix:], "the check isn&#39;t installed on this server") {
		t.Fatal("checks page doesn't list it to fix")
	}
}

// The tests run as a release build (the Docker build stamps these), so the fleet view's own
// code isn't a finding everywhere; TestOwnServices tests the other cases.
func init() {
	buildVersion, buildCode, bridgeCode = "1.1.1", "8272cc124f7a", "5f74a8885898"
}

func TestOwnServices(t *testing.T) {
	defer func(v, c, b string) { buildVersion, buildCode, bridgeCode = v, c, b }(buildVersion, buildCode, bridgeCode)
	rel := func(r string) *Status {
		return &Status{Data: map[string]any{"version": map[string]any{"latest": map[string]any{"release": r}}}}
	}
	sts := []*Status{rel("v1.1.0"), rel("v1.1.1"), {Err: "down"}}
	if newestRelease(sts) != "1.1.1" || !versionLess("1.1.0", "1.1.1") || versionLess("1.10.0", "1.9.0") || versionLess("1.1.1", "1.1.1") {
		t.Fatal("release order")
	}
	find := func(os []OwnService, name string) OwnService {
		for _, o := range os {
			if o.Name == name {
				return o
			}
		}
		return OwnService{}
	}
	// no community.json: the fleet view alone, on the newest release
	os := ownServices(sts, nil)
	if len(os) != 1 || os[0].Level != "good" || os[0].Runs != "1.1.1 (code 8272cc124f7a)" {
		t.Fatalf("fleet: %+v", os)
	}
	// a newer release is out: update the fleet view
	if o := ownServices([]*Status{rel("v1.2.0")}, nil)[0]; o.Level != "warn" || !strings.Contains(o.Note, "1.2.0 is out") || o.Fix == "" {
		t.Fatalf("older fleet: %+v", o)
	}
	cases := []struct {
		name   string
		bridge *BridgeStatus
		level  string
		note   string
	}{
		{"not named", nil, "warn", `add "signin"`},
		{"same code", &BridgeStatus{Version: "1.1.1", Code: "5f74a8885898"}, "good", "the same code"},
		{"other code", &BridgeStatus{Version: "1.1.1", Code: "0123456789ab"}, "bad", "not the code of release 1.1.1 (5f74a8885898)"},
		{"older build", &BridgeStatus{Err: "it runs an older build that doesn't say which code it runs"}, "bad", "older build"},
		{"unreachable", &BridgeStatus{Err: "can't reach the sign-in bridge: refused"}, "bad", "can't reach"},
	}
	for _, c := range cases {
		o := find(ownServices(sts, &CommunityStatus{Bridge: c.bridge}), "Sign-in bridge")
		if o.Level != c.level || !strings.Contains(o.Note, c.note) || (c.level == "bad" && !strings.Contains(o.Fix, "/opt/steady-ops")) {
			t.Errorf("%s: %+v", c.name, o)
		}
	}
	// a fleet view built without the stamps can't vouch for the bridge, and says so
	buildVersion, buildCode, bridgeCode = "dev", "", ""
	os = ownServices(sts, &CommunityStatus{Bridge: &BridgeStatus{Version: "1.1.1", Code: "5f74a8885898"}})
	if os[0].Level != "warn" || find(os, "Sign-in bridge").Level != "warn" {
		t.Fatalf("dev build: %+v", os)
	}
	// and the checks page lists what's wrong first: the bridge to fix, the fleet view to look at
	buildVersion, buildCode, bridgeCode = "1.1.0", "8272cc124f7a", "5f74a8885898"
	p := makeChecks(sts, &CommunityStatus{Bridge: &BridgeStatus{Version: "1.0.5", Code: "deadbeef0000"}}, time.Now())
	if len(p.Fix) < 1 || p.Fix[0].Server != "Sign-in bridge" || p.Fix[0].Link != "/#code" || !strings.Contains(p.Fix[0].Text, "runs 1.0.5 (code deadbeef0000)") {
		t.Fatalf("fix: %+v", p.Fix)
	}
	if len(p.Look) < 1 || p.Look[0].Server != "Fleet view" || !strings.Contains(p.Look[0].Text, "1.1.1 is out") {
		t.Fatalf("look: %+v", p.Look)
	}
}

// The fleet view asks the bridge which code it runs; an older bridge has no /version.
func TestFetchBridge(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/version" {
			w.Write([]byte(`{"version":"1.1.1","code":"5f74a8885898"}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	p := NewPoller(NewStore(t.TempDir()))
	if b := p.fetchBridge(context.Background(), srv.URL); b.Err != "" || b.Version != "1.1.1" || b.Code != "5f74a8885898" {
		t.Fatalf("bridge: %+v", b)
	}
	old := httptest.NewServer(http.NotFoundHandler())
	defer old.Close()
	if b := p.fetchBridge(context.Background(), old.URL); !strings.Contains(b.Err, "older build") {
		t.Fatalf("old bridge: %+v", b)
	}
}

// Behind the newest signed release: on the checks page to look at, and counted on the overview.
func TestServerBehindIsListed(t *testing.T) {
	behind := &Status{Server: Server{Name: "VR"}, At: time.Now(), Data: map[string]any{
		"version": map[string]any{"code": "abc1234", "managed": true, "signed": true, "behind": 3.0,
			"current": map[string]any{"version": "1.1.0"}, "latest": map[string]any{"release": "v1.1.1"}},
		"audit": map[string]any{"at": time.Now().Format(time.RFC3339), "items": []any{}}}}
	branch := &Status{Server: Server{Name: "Test"}, At: time.Now(), Data: map[string]any{
		"version": map[string]any{"code": "def5678", "managed": true, "signed": false, "behind": 2.0},
		"audit":   map[string]any{"at": time.Now().Format(time.RFC3339), "items": []any{}}}}
	p := makeChecks([]*Status{behind, branch}, nil, time.Now())
	var got []string
	for _, it := range p.Look {
		if it.Section == "Version" {
			got = append(got, it.Server+": "+it.Text)
		}
	}
	if len(got) != 1 || !strings.Contains(got[0], "VR: runs 1.1.0, 3 change(s) behind the newest signed release (1.1.1)") {
		t.Fatalf("behind: %v", got)
	}
}

// An admin watches, reads and reports: the server page tells them devs make changes, and shows
// no commands. Roles are set from the command line, and logged.
func TestAdminsSeeNoCommands(t *testing.T) {
	app, site, _, _, dir := setup(t)
	admin := NewUser("anna", "a long enough password")
	admin.Role = "admin"
	if err := app.store.UpdateUsers(func(all []User) ([]User, error) { return append(all, admin), nil }); err != nil {
		t.Fatal(err)
	}
	c := signIn(t, site, &admin, time.Now())
	res, _ := c.Get(site.URL + "/s/0")
	page := body(t, res)
	if strings.Contains(page, "fleet.sh") || !strings.Contains(page, "OpenWorks' devs make changes to servers over SSH") {
		t.Fatal("an admin sees the SSH commands, or not the note")
	}
	// made a dev: the commands show on the next page, without signing in again
	t.Setenv("FLEET_ACTOR", "tiaan")
	if err := setRole(app.store, "anna", "dev"); err != nil {
		t.Fatal(err)
	}
	res, _ = c.Get(site.URL + "/s/0")
	if !strings.Contains(body(t, res), "fleet.sh update") {
		t.Fatal("a new dev doesn't see the commands")
	}
	if err := setRole(app.store, "anna", "root"); err == nil {
		t.Fatal("a role that doesn't exist was set")
	}
	var out strings.Builder
	if err := listUsers(app.store, &out); err != nil || !strings.Contains(out.String(), "jane                 dev") || !strings.Contains(out.String(), "anna                 dev") {
		t.Fatalf("users: %v %q", err, out.String())
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	if !strings.Contains(string(b), `"detail":"anna: dev","ip":"ssh","what":"setrole","who":"tiaan (ssh)"`) {
		t.Fatalf("setrole isn't logged: %s", b)
	}
}

func TestShortNames(t *testing.T) {
	for url, want := range map[string]string{
		"https://vr.steadyapp.co.za": "vr", "https://Test.SteadyApp.co.za/": "test", "http://127.0.0.1:8090": "127.0.0.1",
	} {
		if got := (Server{URL: url}).ShortName(); got != want {
			t.Errorf("%s: %q", url, got)
		}
	}
}

// A dev resets a staff password over SSH: confirmed by typing the server's short name, the
// temporary password shown once, the account in the log but never the password.
func TestResetOverSSH(t *testing.T) {
	app, _, steady, _, dir := setup(t)
	t.Setenv("FLEET_ACTOR", "tiaan")
	var out strings.Builder
	if err := resetPassword(app.store, []string{"127.0.0.1"}, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatalf("no email: %v", err)
	}
	if err := resetPassword(app.store, []string{"127.0.0.1", "two@example.org"}, strings.NewReader("nope\n"), &out); err == nil || !strings.Contains(err.Error(), "not confirmed") {
		t.Fatalf("unconfirmed: %v", err)
	}
	out.Reset()
	if err := resetPassword(app.store, []string{"127.0.0.1", "Two@Example.org", "--two-step"}, strings.NewReader("127.0.0.1\n"), &out); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Temporary password:  Tmp-4821-quiet-otter", "by phone", "emailed to t***@example.org", "Two-step sign-in was cleared"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("output lacks %q:\n%s", want, out.String())
		}
	}
	if err := resetPassword(app.store, []string{"127.0.0.1", "pat@example.org", "--yes"}, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "Patients' passwords") {
		t.Fatalf("a patient: %v", err)
	}
	steady.mu.Lock()
	got := strings.Join(steady.requests, ",")
	steady.mu.Unlock()
	if got != "reset Two@Example.org true,reset pat@example.org false" {
		t.Fatalf("requests: %q", got)
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	if !strings.Contains(string(b), `two@example.org (two-step): ok`) || strings.Contains(string(b), "Tmp-4821") {
		t.Fatalf("the log should name the account and never the password: %s", b)
	}
}

// Feedback that has waited a week, and OpenWorks accounts left on a practice's server, are
// listed to look at; OpenWorks' own server keeps its support account.
func TestFeedbackAndSupportAccountsOnChecks(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	mk := func(name string, own bool, oldest time.Time) *Status {
		return &Status{Server: Server{Name: name, URL: "https://" + strings.ToLower(name) + ".steadyapp.co.za"}, At: now, Data: map[string]any{
			"counts":            map[string]any{"feedbackNew": 3.0, "feedbackNewBugs": 1.0, "supportAccounts": 1.0},
			"feedbackOldestNew": oldest.Format(time.RFC3339), "openworksServer": own,
			"audit": map[string]any{"at": now.Format(time.RFC3339), "items": []any{}}}}
	}
	p := makeChecks([]*Status{mk("VR", false, now.Add(-8*24*time.Hour)), mk("Test", true, now.Add(-2*24*time.Hour))}, nil, now)
	var got []string
	for _, it := range p.Look {
		got = append(got, it.Server+" "+it.Section)
	}
	if strings.Join(got, ",") != "VR Feedback,VR Accounts" {
		t.Fatalf("look: %v", got)
	}
	if f := feedbackText(mk("VR", false, now.Add(-8*24*time.Hour)).Data, now); f != "3 new (1 bug report), the oldest 8 days ago" {
		t.Fatalf("feedback fact: %q", f)
	}
}

// The community run from here: switched on with a key the fleet makes and hands to the server,
// staff approved from the practice's own list, the bridge's file written in its format, someone
// the practice takes out removed at the next poll, and off again.
func TestCommunityFromTheFleet(t *testing.T) {
	app, site, steady, u, dir := setup(t)
	t.Setenv("FLEET_ACTOR", "tiaan")
	member := func(email, name, role string) any { return map[string]any{"email": email, "name": name, "role": role} }
	steady.mu.Lock()
	steady.comm = map[string]any{"on": false, "fleet": false, "members": []any{}}
	steady.mu.Unlock()
	var out strings.Builder
	short := "127.0.0.1"

	// community.json must name the forum and the bridge first
	if err := communityCmd(app.store, []string{short, "on", "--yes"}, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "signin") {
		t.Fatalf("without community.json: %v", err)
	}
	writeJSON(dir+"/community.json", Community{URL: "https://community.steadyapp.co.za", StatsKey: strings.Repeat("5a", 32), Signin: "https://signin.steadyapp.co.za"})
	if err := communityCmd(app.store, []string{short, "on"}, strings.NewReader("no\n"), &out); err == nil || !strings.Contains(err.Error(), "not confirmed") {
		t.Fatalf("unconfirmed: %v", err)
	}
	// the practice already has its master psychologist in: --approve-all takes them
	steady.mu.Lock()
	steady.comm["members"] = []any{member("kempie@vrpsych.co.za", "Dr Kempie", "clinician")}
	steady.mu.Unlock()
	if err := communityCmd(app.store, []string{short, "on", "--approve-all", "--group", "practice-vr", "--yes"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	steady.mu.Lock()
	sent := steady.commSet[len(steady.commSet)-1]
	steady.mu.Unlock()
	key, _ := sent["key"].(string)
	if sent["on"] != true || sent["forum"] != "https://community.steadyapp.co.za" || sent["signin"] != "https://signin.steadyapp.co.za" || len(key) < 40 || sent["openworks"] != false {
		t.Fatalf("sent to the server: %v", sent)
	}
	var bridge []bridgePractice
	readJSON(dir+"/bridge/practices.json", &bridge)
	if len(bridge) != 1 || bridge[0].ID != short || bridge[0].Key != key || strings.Join(bridge[0].Emails, ",") != "kempie@vrpsych.co.za" ||
		strings.Join(bridge[0].Groups, ",") != "practice-vr" || bridge[0].Name != "VR Clinical Psychology" || bridge[0].Support {
		t.Fatalf("bridge file: %+v", bridge)
	}
	if st, _ := os.Stat(dir + "/bridge/practices.json"); st.Mode().Perm() != 0o600 {
		t.Fatalf("the bridge's file is %v", st.Mode().Perm())
	}

	// the master psychologist adds two more: they wait, and only listed staff can be approved
	steady.mu.Lock()
	steady.comm["members"] = []any{member("kempie@vrpsych.co.za", "Dr Kempie", "clinician"), member("two@vrpsych.co.za", "Dr Two", "clinician"), member("desk@vrpsych.co.za", "Front Desk", "admin")}
	steady.mu.Unlock()
	out.Reset()
	if err := communityCmd(app.store, []string{short, "people"}, strings.NewReader(""), &out); err != nil || strings.Count(out.String(), "WAITING") != 2 {
		t.Fatalf("people: %v\n%s", err, out.String())
	}
	if err := communityCmd(app.store, []string{short, "approve", "stranger@gmail.com"}, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "isn't on") {
		t.Fatalf("a stranger: %v", err)
	}
	if err := communityCmd(app.store, []string{short, "approve", "Two@VRpsych.co.za", "desk@vrpsych.co.za"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	readJSON(dir+"/bridge/practices.json", &bridge)
	if strings.Join(bridge[0].Emails, ",") != "desk@vrpsych.co.za,kempie@vrpsych.co.za,two@vrpsych.co.za" {
		t.Fatalf("after approving: %v", bridge[0].Emails)
	}

	// the website shows it on the server's page; nobody waits now
	app.poller.PollAll(context.Background())
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/s/0")
	page := body(t, res)
	if !strings.Contains(page, "On, run from the fleet view. 3 staff approved.") {
		t.Fatalf("server page: %s", page[strings.Index(page, `id="community"`):][:300])
	}

	// the practice takes Dr Two out: off the bridge's list at the next poll, and logged
	steady.mu.Lock()
	steady.comm["members"] = []any{member("kempie@vrpsych.co.za", "Dr Kempie", "clinician"), member("desk@vrpsych.co.za", "Front Desk", "admin"), member("new@vrpsych.co.za", "Dr New", "clinician")}
	steady.mu.Unlock()
	app.poller.PollAll(context.Background())
	readJSON(dir+"/bridge/practices.json", &bridge)
	if strings.Join(bridge[0].Emails, ",") != "desk@vrpsych.co.za,kempie@vrpsych.co.za" {
		t.Fatalf("after the practice took one out: %v", bridge[0].Emails)
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	if !strings.Contains(string(b), "two@vrpsych.co.za (taken out by the practice)") || !strings.Contains(string(b), `"what":"community approve"`) {
		t.Fatalf("log: %s", b)
	}
	// the new one waits: on the page with the command, and on Checks
	res, _ = c.Get(site.URL + "/s/0")
	page = body(t, res)
	if !strings.Contains(page, "1 waiting for approval") || !strings.Contains(page, "fleet.sh community 127.0.0.1 approve new@vrpsych.co.za") {
		t.Fatal("the waiting one isn't on the page with its command")
	}
	res, _ = c.Get(site.URL + "/checks")
	if !strings.Contains(body(t, res), "1 staff waiting for OpenWorks&#39; approval") {
		t.Fatal("Checks doesn't list the waiting one")
	}

	// switched off: off at the server, and gone from the bridge's list
	if err := communityCmd(app.store, []string{short, "off", "--yes"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	readJSON(dir+"/bridge/practices.json", &bridge)
	if len(bridge) != 0 {
		t.Fatalf("after off: %+v", bridge)
	}
	steady.mu.Lock()
	last := steady.commSet[len(steady.commSet)-1]
	steady.mu.Unlock()
	if last["on"] != false {
		t.Fatalf("off wasn't sent: %v", last)
	}
}

// What the fleet view and a server disagree about shows on Checks.
func TestCommunityDisagreements(t *testing.T) {
	st := func(c map[string]any) *Status {
		return &Status{Server: Server{Name: "VR", URL: "https://vr.steadyapp.co.za"}, At: time.Now(), Data: map[string]any{"community": c}}
	}
	runs := &CommunityPractices{Practices: map[string]*CommunityPractice{"vr": {ID: "vr", Approved: []string{"k@vr.co.za"}}}}
	for _, c := range []struct {
		data  map[string]any
		runs  *CommunityPractices
		level string
		note  string
	}{
		{map[string]any{"on": false, "members": []any{}}, runs, "fail", "says it's off"},
		{map[string]any{"on": true, "fleet": true, "members": []any{}}, &CommunityPractices{Practices: map[string]*CommunityPractice{}}, "fail", "no longer runs"},
		{map[string]any{"on": true, "fleet": false, "members": []any{}}, nil, "warn", "runs from .env"},
		{map[string]any{"on": true, "fleet": true, "members": []any{map[string]any{"email": "k@vr.co.za"}}}, runs, "", ""},
		{map[string]any{"on": false, "members": []any{}}, nil, "", ""},
	} {
		v := makeServerCommunity(st(c.data), c.runs)
		if v.Level != c.level || !strings.Contains(v.Note, c.note) {
			t.Errorf("%v: %+v", c.data, v)
		}
	}
}

// A practice with nobody approved stays off the bridge's list: the bridge refuses a practice
// without addresses, and would set aside every other practice with it (1.2.0 on VR, before its
// server could read the fleet view's setting).
func TestEmptyPracticeOffTheBridge(t *testing.T) {
	app, _, steady, _, dir := setup(t)
	t.Setenv("FLEET_ACTOR", "tiaan")
	writeJSON(dir+"/community.json", Community{URL: "https://community.steadyapp.co.za", StatsKey: strings.Repeat("5a", 32), Signin: "https://signin.steadyapp.co.za"})
	// another practice the fleet view already runs, with someone approved
	err := app.store.withCommunity(func(cp *CommunityPractices) (bool, error) {
		cp.Practices["test"] = &CommunityPractice{ID: "test", Name: "Test", URL: "https://test.steadyapp.co.za", Key: strings.Repeat("k", 43), OpenWorks: true, Approved: []string{"test@openworks.co.za"}}
		return true, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// this server is on Steady 1.2.0: it says off, with nobody
	steady.mu.Lock()
	steady.comm = map[string]any{"on": false, "fleet": true, "members": []any{}}
	steady.commOld = true
	steady.mu.Unlock()
	var out strings.Builder
	if err := communityCmd(app.store, []string{"127.0.0.1", "on", "--approve-all", "--yes"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"still says the community is off", "Update it, then run this again", "Nobody is approved yet, so the sign-in bridge doesn't list"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("missing %q in:\n%s", want, out.String())
		}
	}
	var bridge []bridgePractice
	readJSON(dir+"/bridge/practices.json", &bridge)
	if len(bridge) != 1 || bridge[0].ID != "test" {
		t.Fatalf("bridge file: %+v", bridge)
	}
	// updated, the practice has its master psychologist in: on again, and on the list
	steady.mu.Lock()
	steady.comm = map[string]any{"on": true, "fleet": true, "members": []any{map[string]any{"email": "kempie@vrpsych.co.za", "name": "Dr Kempie", "role": "clinician"}}}
	steady.commOld = false
	steady.mu.Unlock()
	out.Reset()
	if err := communityCmd(app.store, []string{"127.0.0.1", "on", "--approve-all", "--yes"}, strings.NewReader(""), &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "still says") || strings.Contains(out.String(), "Nobody is approved") || !strings.Contains(out.String(), "Approved now: kempie@vrpsych.co.za") {
		t.Fatalf("second time:\n%s", out.String())
	}
	readJSON(dir+"/bridge/practices.json", &bridge)
	if len(bridge) != 2 {
		t.Fatalf("bridge file: %+v", bridge)
	}
}
