// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard) // refusals are logged; not needed here
	os.Exit(m.Run())
}

const (
	forumSecret = "forum-secret-forum-secret-forum-secret-1234"
	vrKey       = "vr-key-vr-key-vr-key-vr-key-vr-key-vr-key-12"
	testKey     = "test-key-test-key-test-key-test-key-test-key"
	forum       = "https://community.example.org"
	bridgeURL   = "https://signin.example.org"
)

func writeConfig(t *testing.T, c map[string]any) string {
	t.Helper()
	b, _ := json.Marshal(c)
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func settings() map[string]any {
	return map[string]any{
		"url": bridgeURL + "/", "forum": "HTTPS://Community.Example.org", "forumSecret": forumSecret,
		"openworks": []string{"IT@OpenWorks.example"},
		"practices": []map[string]any{
			{"id": "vr", "name": "VR Clinical Psychology", "url": "https://vr.example.org", "key": vrKey, "groups": []string{"Practice-VR"}, "emails": []string{"@VRpsych.example"}},
			{"id": "test", "name": "Steady Test", "url": "https://test.example.org/", "key": testKey, "emails": []string{"tester@gmail.com"}, "support": true},
		},
	}
}

type rig struct {
	t     *testing.T
	app   *App
	clock time.Time
	jti   int
}

func newRig(t *testing.T, c map[string]any) *rig {
	r := &rig{t: t, clock: time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)}
	en := NewEntries(2*time.Minute, 5000, 20)
	en.now = func() time.Time { return r.clock }
	r.app = NewApp(NewConfigFile(writeConfig(t, c)), en, "")
	r.app.now = func() time.Time { return r.clock }
	return r
}

// get: one request, with these cookies (from Steady's frame, as a browser would say).
func (r *rig) get(target string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", target, nil)
	req.RemoteAddr = "198.51.100.7:4000"
	req.Header.Set("Sec-Fetch-Site", "same-site")
	for _, c := range cookies {
		req.AddCookie(c)
	}
	w := httptest.NewRecorder()
	r.app.Routes().ServeHTTP(w, req)
	return w
}

func (r *rig) note(role, email string) note {
	r.jti++
	now := r.clock.Unix()
	return note{V: 1, Aud: bridgeURL, Jti: fmt.Sprintf("jti%021d", r.jti), Sub: "abcdefghij12345", Email: email,
		Name: "Dr Kempie\nvan Rooyen", Role: role, Iat: now, Exp: now + 120}
}

// steadySays: the Community tab's first address (server/pb_hooks/lib/community.js).
func steadySays(key string, n note) string {
	b, _ := json.Marshal(n)
	return "/enter?" + url.Values{"p": {string(b)}, "s": {sign(key, string(b))}}.Encode()
}

// forumAsks: what Discourse sends (DiscourseConnect.generate_url).
func forumAsks(secret, nonce, returnTo string) string {
	payload := base64.StdEncoding.EncodeToString([]byte(url.Values{"nonce": {nonce}, "return_sso_url": {returnTo}}.Encode()))
	return "/discourse?" + url.Values{"sso": {payload}, "sig": {sign(secret, payload)}}.Encode()
}

func entryCookie(t *testing.T, w *httptest.ResponseRecorder) *http.Cookie {
	t.Helper()
	for _, c := range w.Result().Cookies() {
		if c.Name == cookieName {
			if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteLaxMode || c.Path != "/discourse" || c.MaxAge <= 0 || c.MaxAge > 120 {
				t.Fatalf("cookie: %+v", c)
			}
			return c
		}
	}
	t.Fatalf("no %s cookie: %d %s", cookieName, w.Code, w.Body.String())
	return nil
}

// enter: Steady's note in; on to the forum with the cookie.
func (r *rig) enter(key string, n note) *http.Cookie {
	r.t.Helper()
	w := r.get(steadySays(key, n))
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != forum+"/session/sso" {
		r.t.Fatalf("enter: %d %q %s", w.Code, w.Header().Get("Location"), w.Body.String())
	}
	return entryCookie(r.t, w)
}

func forumGets(t *testing.T, w *httptest.ResponseRecorder) url.Values {
	t.Helper()
	if w.Code != http.StatusSeeOther {
		t.Fatalf("expected the way to the forum, got %d: %s", w.Code, w.Body.String())
	}
	u, _ := url.Parse(w.Header().Get("Location"))
	if u.Scheme+"://"+u.Host+u.Path != forum+"/session/sso_login" {
		t.Fatalf("sent to %s", u)
	}
	sso, sig := u.Query().Get("sso"), u.Query().Get("sig")
	if !signedBy(forumSecret, sso, sig) {
		t.Fatal("the forum's payload isn't signed with its secret")
	}
	raw, err := base64.StdEncoding.DecodeString(sso)
	if err != nil {
		t.Fatal(err)
	}
	v, _ := url.ParseQuery(string(raw))
	return v
}

func TestThePsychologistInSteadyArrives(t *testing.T) {
	r := newRig(t, settings())
	c := r.enter(vrKey, r.note("clinician", "Kempie@VRpsych.example"))
	v := forumGets(t, r.get(forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c))
	want := map[string]string{
		"nonce": "a1b2c3d4e5f6a7b8", "external_id": "vr:abcdefghij12345", "email": "kempie@vrpsych.example",
		"name": "Dr Kempie van Rooyen", "title": "VR Clinical Psychology", "add_groups": "clinicians,practice-vr",
		"remove_groups": "practice-admins,openworks", "require_activation": "false",
	}
	for k, x := range want {
		if v.Get(k) != x {
			t.Errorf("%s = %q, want %q", k, v.Get(k), x)
		}
	}
	for _, k := range []string{"admin", "moderator", "username", "groups"} {
		if v.Has(k) {
			t.Errorf("%s must be left to the forum", k)
		}
	}
	// the cookie works once
	if w := r.get(forumAsks(forumSecret, "b1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c); w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), `data-message="sign-in"`) {
		t.Fatalf("used twice: %d", w.Code)
	}
}

func TestOpenWorksSupportJoinsOpenWorksOnly(t *testing.T) {
	r := newRig(t, settings())
	c := r.enter(testKey, r.note("support", "it@openworks.example"))
	v := forumGets(t, r.get(forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c))
	if v.Get("add_groups") != "openworks" || v.Get("remove_groups") != "clinicians,practice-admins,practice-vr" || v.Get("external_id") != "test:abcdefghij12345" || v.Get("title") != "OpenWorks IT" {
		t.Fatalf("support: %v", v)
	}
}

func TestMovingPracticeLeavesTheOldPracticesGroup(t *testing.T) {
	r := newRig(t, settings())
	c := r.enter(testKey, r.note("clinician", "tester@gmail.com"))
	v := forumGets(t, r.get(forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c))
	if v.Get("add_groups") != "clinicians" || v.Get("remove_groups") != "practice-admins,openworks,practice-vr" {
		t.Fatalf("groups: %v", v)
	}
}

func TestThePracticeAdminSeesTheManualOnly(t *testing.T) {
	r := newRig(t, settings())
	// on the practice's own list, like its psychologists
	c := r.enter(vrKey, r.note("admin", "Desk@VRpsych.example"))
	v := forumGets(t, r.get(forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c))
	want := map[string]string{
		"external_id": "vr:abcdefghij12345", "email": "desk@vrpsych.example", "title": "VR Clinical Psychology",
		// never clinicians, OpenWorks or the practice's private group (that's for its psychologists)
		"add_groups": "practice-admins", "remove_groups": "clinicians,openworks,practice-vr",
	}
	for k, x := range want {
		if v.Get(k) != x {
			t.Errorf("%s = %q, want %q", k, v.Get(k), x)
		}
	}
}

func TestRefusalsSayWhoTheCommunityIsFor(t *testing.T) {
	r := newRig(t, settings())
	for _, n := range []note{r.note("patient", "p@vrpsych.example"), r.note("support", "it@openworks.example")} {
		w := r.get(steadySays(vrKey, n))
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "psychologists, practice administrators and OpenWorks IT") {
			t.Errorf("%s: %d %s", n.Role, w.Code, w.Body.String())
		}
	}
}

// Someone whose role changes in Steady (an administrator who becomes a psychologist, or the
// other way round) ends up in the right groups at their next sign-in.
func TestGroupsFollowTheRole(t *testing.T) {
	c := &Config{}
	b, _ := json.Marshal(settings())
	json.Unmarshal(b, c)
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	vr := c.practice("vr")
	for role, want := range map[string][2]string{
		"clinician": {"clinicians,practice-vr", "practice-admins,openworks"},
		"admin":     {"practice-admins", "clinicians,openworks,practice-vr"},
		"support":   {"openworks", "clinicians,practice-admins,practice-vr"},
		// refused before it gets here; if one ever did, it would join nothing
		"patient": {"", "clinicians,practice-admins,openworks,practice-vr"},
	} {
		add, remove := groupsFor(role, vr, c)
		if got := [2]string{strings.Join(add, ","), strings.Join(remove, ",")}; got != want {
			t.Errorf("%s: add %q remove %q, want %q", role, got[0], got[1], want)
		}
	}
}

func TestEntryOnlyFromSteady(t *testing.T) {
	r := newRig(t, settings())
	for site, ok := range map[string]bool{"same-site": true, "none": true, "": true, "cross-site": false} {
		req := httptest.NewRequest("GET", steadySays(vrKey, r.note("clinician", "kempie@vrpsych.example")), nil)
		req.RemoteAddr = "198.51.100.7:4000"
		if site != "" {
			req.Header.Set("Sec-Fetch-Site", site)
		}
		w := httptest.NewRecorder()
		r.app.Routes().ServeHTTP(w, req)
		if (w.Code == http.StatusSeeOther) != ok {
			t.Errorf("Sec-Fetch-Site %q: %d", site, w.Code)
		}
	}
}

func TestTheForumOnItsOwnSaysOpenSteady(t *testing.T) {
	r := newRig(t, settings())
	ask := forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login")
	for name, cookies := range map[string][]*http.Cookie{
		"no cookie":        nil,
		"a made-up cookie": {{Name: cookieName, Value: strings.Repeat("A", 43)}},
		"a broken cookie":  {{Name: cookieName, Value: "x"}},
	} {
		w := r.get(ask, cookies...)
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "opens inside Steady") || !strings.Contains(w.Body.String(), `data-message="sign-in"`) {
			t.Errorf("%s: %d %s", name, w.Code, w.Body.String())
		}
	}
	for _, p := range []string{"/", "/outside"} {
		if w := r.get(p); w.Code != 200 || !strings.Contains(w.Body.String(), "opens inside Steady") {
			t.Errorf("%s: %d", p, w.Code)
		}
	}
	if w := r.get("/signed-out"); !strings.Contains(w.Body.String(), `data-message="signed-out"`) {
		t.Errorf("signed out: %s", w.Body.String())
	}
}

func TestTheForumsRequestIsChecked(t *testing.T) {
	for name, target := range map[string]string{
		"another secret":       forumAsks("not-the-forum-secret-not-the-forum-secret", "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"),
		"another return":       forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", "https://evil.example.org/session/sso_login"),
		"no nonce":             forumAsks(forumSecret, "", forum+"/session/sso_login"),
		"no signature":         "/discourse?sso=bm9uY2U9YWJj",
		"nothing":              "/discourse",
		"a signature, not hex": "/discourse?sso=bm9uY2U9YWJj&sig=zz",
	} {
		r := newRig(t, settings())
		c := r.enter(vrKey, r.note("clinician", "kempie@vrpsych.example"))
		if w := r.get(target, c); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
}

func TestSteadysNoteIsChecked(t *testing.T) {
	cases := map[string]func(r *rig) string{
		"no practice's key": func(r *rig) string {
			return steadySays("not-a-practice-key-not-a-practice-key-123", r.note("clinician", "kempie@vrpsych.example"))
		},
		"a changed note": func(r *rig) string {
			b, _ := json.Marshal(r.note("clinician", "kempie@vrpsych.example"))
			sig := sign(vrKey, string(b))
			b2, _ := json.Marshal(r.note("clinician", "someone@vrpsych.example"))
			return "/enter?" + url.Values{"p": {string(b2)}, "s": {sig}}.Encode()
		},
		"too old": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.Iat -= 300
			n.Exp -= 300
			return steadySays(vrKey, n)
		},
		"lasting too long": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.Exp += 3600
			return steadySays(vrKey, n)
		},
		"another bridge": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.Aud = "https://signin.elsewhere.example"
			return steadySays(vrKey, n)
		},
		"a patient": func(r *rig) string { return steadySays(vrKey, r.note("patient", "p@vrpsych.example")) },
		"a practice admin not on the practice's list": func(r *rig) string {
			return steadySays(vrKey, r.note("admin", "desk@elsewhere.example"))
		},
		"another practice's admin": func(r *rig) string {
			// the test server vouching for a VR address
			return steadySays(testKey, r.note("admin", "desk@vrpsych.example"))
		},
		"a practice admin with OpenWorks' address": func(r *rig) string {
			return steadySays(testKey, r.note("admin", "it@openworks.example"))
		},
		"another practice's psychologist": func(r *rig) string {
			// the test server vouching for a VR address
			return steadySays(testKey, r.note("clinician", "kempie@vrpsych.example"))
		},
		"a look-alike domain": func(r *rig) string {
			return steadySays(vrKey, r.note("clinician", "kempie@vrpsych.example.evil"))
		},
		"a practice claiming to be OpenWorks": func(r *rig) string {
			return steadySays(vrKey, r.note("support", "kempie@vrpsych.example"))
		},
		"OpenWorks' address from a practice not marked for support": func(r *rig) string {
			return steadySays(vrKey, r.note("support", "it@openworks.example"))
		},
		"support with an address not on the OpenWorks list": func(r *rig) string {
			return steadySays(testKey, r.note("support", "someone@openworks.example"))
		},
		"a bad address": func(r *rig) string {
			return steadySays(vrKey, r.note("clinician", "kempie@vrpsych.example\r\nbcc:x@vrpsych.example"))
		},
		"an odd account id": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.Sub = "../../admin"
			return steadySays(vrKey, n)
		},
		"no note id": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.Jti = ""
			return steadySays(vrKey, n)
		},
		"another version": func(r *rig) string {
			n := r.note("clinician", "kempie@vrpsych.example")
			n.V = 2
			return steadySays(vrKey, n)
		},
	}
	for name, make := range cases {
		r := newRig(t, settings())
		w := r.get(make(r))
		if w.Code == http.StatusSeeOther || w.Code == 200 {
			t.Errorf("%s: let through (%d)", name, w.Code)
		}
		for _, c := range w.Result().Cookies() {
			if c.Name == cookieName && c.MaxAge > 0 {
				t.Errorf("%s: a cookie was handed out", name)
			}
		}
	}
}

func TestANoteWorksOnce(t *testing.T) {
	r := newRig(t, settings())
	n := r.note("clinician", "kempie@vrpsych.example")
	r.enter(vrKey, n)
	if w := r.get(steadySays(vrKey, n)); w.Code == http.StatusSeeOther {
		t.Fatal("the same note let in twice")
	}
}

func TestEntriesExpire(t *testing.T) {
	r := newRig(t, settings())
	c := r.enter(vrKey, r.note("clinician", "kempie@vrpsych.example"))
	r.clock = r.clock.Add(3 * time.Minute)
	if w := r.get(forumAsks(forumSecret, "a1b2c3d4e5f6a7b8", forum+"/session/sso_login"), c); w.Code != http.StatusForbidden {
		t.Fatalf("after 3 minutes: %d", w.Code)
	}
}

func TestLimits(t *testing.T) {
	r := newRig(t, settings())
	for i := 0; i < 20; i++ {
		r.enter(vrKey, r.note("clinician", "kempie@vrpsych.example"))
	}
	if w := r.get(steadySays(vrKey, r.note("clinician", "kempie@vrpsych.example"))); w.Code != http.StatusTooManyRequests {
		t.Fatalf("21st sign-in under way from one address: %d", w.Code)
	}
	r.clock = r.clock.Add(3 * time.Minute)
	r.enter(vrKey, r.note("clinician", "kempie@vrpsych.example"))
	for i := 0; i < windowLimit; i++ {
		r.get("/enter?p=x&s=y")
	}
	if w := r.get(steadySays(vrKey, r.note("clinician", "kempie@vrpsych.example"))); w.Code != http.StatusTooManyRequests {
		t.Fatalf("over the request limit: %d", w.Code)
	}
	// a full table: the oldest gives way rather than everyone being refused
	en := NewEntries(time.Minute, 2, 10)
	for i := 0; i < 3; i++ {
		if _, err := en.Add(note{Jti: fmt.Sprintf("j%d", i), Exp: time.Now().Unix() + 60}, "vr", fmt.Sprintf("10.0.0.%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if len(en.m) != 2 {
		t.Fatalf("entries: %d", len(en.m))
	}
}

func TestPagesAndHeaders(t *testing.T) {
	r := newRig(t, settings())
	for _, p := range []string{"/", "/signed-out", "/healthz", "/app.css", "/app.js"} {
		w := r.get(p)
		if w.Code != 200 {
			t.Errorf("%s: %d", p, w.Code)
		}
		csp := w.Header().Get("Content-Security-Policy")
		if w.Header().Get("Referrer-Policy") != "no-referrer" || !strings.Contains(csp, "default-src 'none'") ||
			!strings.Contains(csp, "frame-ancestors 'self' https://vr.example.org https://test.example.org;") {
			t.Errorf("%s: headers %v", p, w.Header())
		}
	}
	if w := r.get("/app.js"); !strings.HasPrefix(w.Header().Get("Content-Type"), "text/javascript") {
		t.Error("app.js type")
	}
	if w := r.get("/nothing-here"); w.Code != 404 {
		t.Errorf("unknown page: %d", w.Code)
	}
	// broken settings: pages say so, the health check fails, and neither shows why
	bad := NewApp(NewConfigFile(filepath.Join(t.TempDir(), "missing.json")), NewEntries(time.Minute, 10, 10), "")
	for _, p := range []string{"/healthz", "/discourse", "/enter"} {
		w := httptest.NewRecorder()
		bad.Routes().ServeHTTP(w, httptest.NewRequest("GET", p, nil))
		if w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), "missing.json") {
			t.Errorf("%s without settings: %d %s", p, w.Code, w.Body.String())
		}
	}
}

func TestSettingsAreChecked(t *testing.T) {
	c := &Config{}
	b, _ := json.Marshal(settings())
	json.Unmarshal(b, c)
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	if c.URL != bridgeURL || c.Forum != forum || c.Practices[1].URL != "https://test.example.org" || c.Practices[0].Groups[0] != "practice-vr" ||
		c.Practices[0].Emails[0] != "@vrpsych.example" || c.OpenWorks[0] != "it@openworks.example" {
		t.Fatalf("tidied: %+v", c)
	}
	practice := func(m map[string]any, i int) map[string]any { return m["practices"].([]map[string]any)[i] }
	breaks := map[string]func(m map[string]any){
		"http forum":            func(m map[string]any) { m["forum"] = "http://community.example.org" },
		"forum with a path":     func(m map[string]any) { m["forum"] = "https://community.example.org/x" },
		"short secret":          func(m map[string]any) { m["forumSecret"] = "short" },
		"no practices":          func(m map[string]any) { m["practices"] = []map[string]any{} },
		"same id":               func(m map[string]any) { practice(m, 1)["id"] = "vr" },
		"odd id":                func(m map[string]any) { practice(m, 1)["id"] = "Test!" },
		"same key":              func(m map[string]any) { practice(m, 1)["key"] = vrKey },
		"key is the secret":     func(m map[string]any) { practice(m, 1)["key"] = forumSecret },
		"short key":             func(m map[string]any) { practice(m, 1)["key"] = "short" },
		"practice over http":    func(m map[string]any) { practice(m, 1)["url"] = "http://test.example.org" },
		"the clinicians group":  func(m map[string]any) { practice(m, 0)["groups"] = []string{"clinicians"} },
		"the admins' group":     func(m map[string]any) { practice(m, 0)["groups"] = []string{"practice-admins"} },
		"a group of admins":     func(m map[string]any) { practice(m, 0)["groups"] = []string{"admins x"} },
		"no address list":       func(m map[string]any) { delete(practice(m, 1), "emails") },
		"an empty list":         func(m map[string]any) { practice(m, 1)["emails"] = []string{} },
		"a bad domain":          func(m map[string]any) { practice(m, 0)["emails"] = []string{"@nodot"} },
		"a bad address":         func(m map[string]any) { practice(m, 0)["emails"] = []string{"not an address"} },
		"a public mail domain":  func(m map[string]any) { practice(m, 1)["emails"] = []string{"@gmail.com"} },
		"two lists, one domain": func(m map[string]any) { practice(m, 1)["emails"] = []string{"@vrpsych.example"} },
		"an address under another's domain": func(m map[string]any) {
			practice(m, 1)["emails"] = []string{"kempie@vrpsych.example"}
		},
		"one address on two lists": func(m map[string]any) {
			practice(m, 0)["emails"] = []string{"@vrpsych.example", "tester@gmail.com"}
		},
		"a practice listing OpenWorks": func(m map[string]any) {
			practice(m, 1)["emails"] = []string{"it@openworks.example"}
		},
		"OpenWorks as a whole domain": func(m map[string]any) { m["openworks"] = []string{"@openworks.example"} },
	}
	for name, f := range breaks {
		m := settings()
		f(m)
		if _, err := loadConfig(writeConfig(t, m)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	m := settings()
	m["extra"] = 1
	if _, err := loadConfig(writeConfig(t, m)); err == nil {
		t.Error("an unknown setting (a typo) is accepted")
	}
}

func TestSettingsAreReadAgainWhenChanged(t *testing.T) {
	m := settings()
	p := writeConfig(t, m)
	f := NewConfigFile(p)
	c, err := f.Get()
	if err != nil || len(c.Practices) != 2 {
		t.Fatal(err)
	}
	m["practices"] = m["practices"].([]map[string]any)[:1]
	b, _ := json.Marshal(m)
	os.WriteFile(p, b, 0o600)
	os.Chtimes(p, time.Now().Add(time.Minute), time.Now().Add(time.Minute))
	f.checked = time.Time{}
	if c, err = f.Get(); err != nil || len(c.Practices) != 1 {
		t.Fatalf("after removing a practice: %v %v", c, err)
	}
}

func TestEmailRules(t *testing.T) {
	list := []string{"@vrpsych.co.za", "tiaan@example.org"}
	for e, ok := range map[string]bool{
		"kempie@vrpsych.co.za": true, "tiaan@example.org": true, "x@example.org": false,
		"kempie@evilvrpsych.co.za": false, "kempie@vrpsych.co.za.evil": false,
	} {
		if listed(list, e) != ok {
			t.Errorf("%s: %v", e, !ok)
		}
	}
	for e, ok := range map[string]bool{"a@b.co": true, "a@b": false, "a b@c.co": false, "a@@b.co": false, "<a@b.co>": false, "a@b.co\n": false} {
		if validEmail(e) != ok {
			t.Errorf("valid %q: %v", e, !ok)
		}
	}
	if got := cleanName("  Dr\tA B\x00‮  "); got != "Dr A B" {
		t.Errorf("%q", got)
	}
	if len([]rune(cleanName(strings.Repeat("é", 300)))) != 100 {
		t.Error("names are cut at 100 characters")
	}
}
