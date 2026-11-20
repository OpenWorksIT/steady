// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// A server with three touches: two from one address (a test of ours), one from another.
func touchRig(t *testing.T) (*App, *http.Client, *fakeSteady, string, string) {
	app, site, steady, u, dir := setup(t)
	app.lookup = func(_ context.Context, ip string) Origin {
		return Origin{Names: []string{"scan-7.example.net"}, ASN: "64500", Network: "EXAMPLE-HOSTING - Example Cloud Ltd", Prefix: "198.51.100.0/24", Country: "NL"}
	}
	now := time.Now().UTC()
	steady.mu.Lock()
	steady.door = map[string]any{
		"last24h": map[string]any{"trip": 3}, "last7d": map[string]any{"trip": 5},
		"trips": []any{
			map[string]any{"at": now.Add(-time.Hour).Format(time.RFC3339Nano), "label": "robots path", "type": "path", "where": "the path", "path": "/old-portal/login.php",
				"query": "id=1' OR 1=1&token=…(16)", "method": "GET", "ip": "198.51.100.7", "agent": "Mozilla/5.0 zgrab/0.x <script>", "host": "203.0.113.50",
				"forwarded": "127.0.0.1, 198.51.100.7", "headers": "accept user-agent x-forwarded-for", "status": 404},
			map[string]any{"at": now.Add(-50 * time.Minute).Format(time.RFC3339Nano), "label": "planted in .env", "type": "value", "where": "the Authorization header",
				"path": "/api/steady/fleet", "method": "GET", "ip": "198.51.100.7", "agent": "curl/8.5", "status": 0},
			map[string]any{"at": now.Add(-10 * time.Minute).Format(time.RFC3339Nano), "label": "admin name", "type": "name", "where": "the sign-in name",
				"path": "/api/steady/auth/sign-in", "method": "POST", "ip": "192.0.2.44", "agent": "python-requests/2.31", "status": 400,
				"account": "a psychologist's account: took@vr.example.org"},
		},
	}
	steady.trip = map[string]any{"set": true, "paths": 1, "values": 1, "names": 1, "alertEmail": true, "problems": []any{}}
	steady.trail = map[string]any{"ip": "198.51.100.7", "logs": map[string]any{"days": 5, "ip": true}, "total": 6,
		"first": now.Add(-62 * time.Minute).Format(time.RFC3339Nano), "last": now.Add(-50 * time.Minute).Format(time.RFC3339Nano),
		"signedIn": []any{map[string]any{"as": "an account", "n": 2, "first": now.Add(-61 * time.Minute).Format(time.RFC3339Nano), "last": now.Add(-55 * time.Minute).Format(time.RFC3339Nano)}},
		"requests": []any{
			map[string]any{"at": now.Add(-50 * time.Minute).Format(time.RFC3339Nano), "method": "GET", "path": "/api/steady/fleet", "status": 404, "agent": "curl/8.5"},
			map[string]any{"at": now.Add(-time.Hour).Format(time.RFC3339Nano), "method": "GET", "path": "/old-portal/login.php?id=1' OR 1=1&token=…(16)", "status": 404, "agent": "Mozilla/5.0 zgrab/0.x <script>"},
			map[string]any{"at": now.Add(-62 * time.Minute).Format(time.RFC3339Nano), "method": "GET", "path": "/robots.txt", "status": 200, "agent": "Mozilla/5.0 zgrab/0.x <script>"},
		}, "more": 0}
	steady.mu.Unlock()
	app.poller.PollAll(context.Background())
	return app, signIn(t, site, u, time.Now()), steady, site.URL, dir
}

func touchIDs(t *testing.T, app *App) map[string]string {
	list, err := app.store.Touches()
	if err != nil || len(list) != 3 {
		t.Fatalf("touches.json: %v %+v", err, list)
	}
	out := map[string]string{}
	for _, x := range list {
		out[x.Label] = x.ID
	}
	return out
}

func TestTouchesKeptAndLookedInto(t *testing.T) {
	app, c, steady, site, _ := touchRig(t)
	ids := touchIDs(t, app)
	// polled again: nothing new is added, and a status that arrived later is filled in
	steady.mu.Lock()
	steady.door["trips"].([]any)[1].(map[string]any)["status"] = 404.0
	steady.mu.Unlock()
	app.poller.PollAll(context.Background())
	if list, _ := app.store.Touches(); len(list) != 3 || list[1].Status != 404 || list[1].Seen.IsZero() {
		t.Fatalf("after a second poll: %+v", list)
	}

	// the Front door: each touch links to its page, all still to look into
	res, _ := c.Get(site + "/frontdoor")
	page := body(t, res)
	for _, want := range []string{"A tripwire was touched 3 time(s) this week, not looked at yet", `href="/frontdoor/touch/` + ids["robots path"] + `"`, "look into it",
		"And 2 more this week that the server counted without keeping them"} {
		if !strings.Contains(page, want) {
			t.Fatalf("front door lacks %q:\n%s", want, page)
		}
	}

	// one touch's page: what happened, what it suggests, where from, and the trail
	res, _ = c.Get(site + "/frontdoor/touch/" + ids["robots path"])
	page = body(t, res)
	for _, want := range []string{
		"robots path, touched on VR Clinical Psychology", "not looked at yet",
		"<code>GET /old-portal/login.php?id=1&#39; OR 1=1&amp;token=…(16)</code>", "404, not found",
		"It asked for a path listed only in robots.txt", "It read /robots.txt 2 minutes before.",
		"It claimed to be forwarded for 127.0.0.1", "by its address (203.0.113.50)", "ZGrab, the tool most internet-wide scanners are built on",
		"Its network (EXAMPLE-HOSTING - Example Cloud Ltd) looks like a hosting or cloud company",
		"scan-7.example.net", "AS64500", "https://viz.greynoise.io/ip/198.51.100.7",
		"6 request(s) from this address", "2 of them made with an account", "<strong class=\"error\">the touch</strong>", "the same",
		"planted in .env", // the other touch from this address
		"The same for the other 1 touch(es) from this address",
	} {
		if !strings.Contains(page, want) {
			t.Fatalf("touch page lacks %q:\n%s", want, page)
		}
	}
	if strings.Contains(page, "zgrab/0.x <script>") {
		t.Fatal("not escaped")
	}
	// the signed-in touch from another address says what to do about the account
	res, _ = c.Get(site + "/frontdoor/touch/" + ids["admin name"])
	page = body(t, res)
	if !strings.Contains(page, "It came signed in, with a psychologist&#39;s account: took@vr.example.org") || !strings.Contains(page, "the server keeps no trail for this address") ||
		!strings.Contains(page, "It tried to sign in as a name nobody has") || !strings.Contains(page, "a Python script") {
		t.Fatalf("signed-in touch: %s", page)
	}
	// only kept touches have pages
	for _, bad := range []string{"0123456789abcdef", "nothex", ids["robots path"] + "0"} {
		if res, _ := c.Get(site + "/frontdoor/touch/" + bad); res.StatusCode != 404 {
			t.Fatalf("%s: %d", bad, res.StatusCode)
		}
	}
}

func TestTouchesMarked(t *testing.T) {
	app, c, steady, site, dir := touchRig(t)
	ids := touchIDs(t, app)
	res, _ := c.Get(site + "/frontdoor/touch/" + ids["robots path"])
	csrf := csrfOf(t, body(t, res))
	post := func(id string, v url.Values) string {
		v.Set("csrf", csrf)
		res, _ := c.PostForm(site+"/frontdoor/touch/"+id, v)
		if res.StatusCode != http.StatusSeeOther {
			t.Fatalf("post: %d %s", res.StatusCode, body(t, res))
		}
		body(t, res)
		res, _ = c.Get(site + "/frontdoor/touch/" + id)
		return body(t, res)
	}
	// no form from elsewhere
	if res, _ := c.PostForm(site+"/frontdoor/touch/"+ids["robots path"], url.Values{"csrf": {"x"}, "op": {"test"}}); res.StatusCode != http.StatusForbidden {
		t.Fatalf("no csrf: %d", res.StatusCode)
	}
	// "dealt with" needs to say what was done; a note alone keeps it open
	if page := post(ids["robots path"], url.Values{"op": {"dealt"}}); !strings.Contains(page, "say what was done") {
		t.Fatalf("dealt without a note: %s", page)
	}
	if page := post(ids["robots path"], url.Values{"op": {"note"}, "note": {"Asked Tiaan whether he ran a scan"}}); !strings.Contains(page, "being looked into") || !strings.Contains(page, "Asked Tiaan whether he ran a scan") {
		t.Fatalf("note: %s", page)
	}
	// a test, and the other touch from the same address with it
	page := post(ids["robots path"], url.Values{"op": {"test"}, "note": {"my tripwire test from home"}, "also": {"1"}})
	if !strings.Contains(page, "Marked a test by us. So are the other 1 from this address.") || !strings.Contains(page, "Not looked at after all: reopen") {
		t.Fatalf("marked: %s", page)
	}
	list, _ := app.store.Touches()
	for _, x := range list {
		want := map[string]string{"robots path": "test", "planted in .env": "test", "admin name": ""}[x.Label]
		if x.Verdict != want || (want != "" && x.Notes[len(x.Notes)-1].By != "jane") {
			t.Fatalf("%s: %+v", x.Label, x)
		}
	}
	// the other address's touch is still open, so the Front door, the overview and Checks say 1
	res, _ = c.Get(site + "/frontdoor")
	if page = body(t, res); !strings.Contains(page, "A tripwire was touched 1 time(s) this week, not looked at yet") || !strings.Contains(page, "2 touch(es) this week already marked") ||
		!strings.Contains(page, "a test by us (jane)") {
		t.Fatalf("front door after marking: %s", page)
	}
	res, _ = c.Get(site + "/")
	if ov := body(t, res); !strings.Contains(ov, "1 tripwire touch(es) to look into") {
		t.Fatalf("overview: %s", ov)
	}
	// real and dealt with: the trail is kept with it (none for this address: nothing kept)
	if page = post(ids["admin name"], url.Values{"op": {"dealt"}, "note": {"reset took@ and asked how the name leaked"}}); !strings.Contains(page, "real: dealt with") {
		t.Fatalf("dealt: %s", page)
	}
	res, _ = c.Get(site + "/frontdoor")
	if page = body(t, res); strings.Contains(page, "not looked at yet") || strings.Contains(page, "tripwire touched") {
		t.Fatalf("all marked, the front door still says so: %s", page)
	}
	res, _ = c.Get(site + "/checks")
	if checks := body(t, res); strings.Contains(checks, "a tripwire was touched") {
		t.Fatalf("checks: %s", checks)
	}
	res, _ = c.Get(site + "/")
	if ov := body(t, res); strings.Contains(ov, "to look into") {
		t.Fatalf("overview: %s", ov)
	}
	// dealt with on the address that has a trail: the trail is kept, and shown once the server lets it go
	post(ids["planted in .env"], url.Values{"op": {"reopen"}})
	post(ids["planted in .env"], url.Values{"op": {"dealt"}, "note": {"rotated the real keys in .env"}})
	steady.mu.Lock()
	steady.trail = nil
	steady.mu.Unlock()
	res, _ = c.Get(site + "/frontdoor/touch/" + ids["planted in .env"])
	if page = body(t, res); !strings.Contains(page, "this is the copy kept when it was marked") || !strings.Contains(page, "6 request(s) from this address") {
		t.Fatalf("kept trail: %s", page)
	}
	// every change is in the audit log, with who
	res, _ = c.Get(site + "/audit")
	if a := body(t, res); !strings.Contains(a, "tripwire touch") || !strings.Contains(a, "Marked a test by us: my tripwire test from home (and 1 more from that address)") {
		t.Fatalf("audit: %s", a)
	}
	// the list of every touch: none to look at now, all three under All
	res, _ = c.Get(site + "/frontdoor/touches")
	if page = body(t, res); !strings.Contains(page, "Nothing to look at: every touch has been marked") {
		t.Fatalf("list: %s", page)
	}
	res, _ = c.Get(site + "/frontdoor/touches?show=all")
	if page = body(t, res); strings.Count(page, `<a href="/frontdoor/touch/`) != 3 {
		t.Fatalf("list, all: %s", page)
	}
	// kept across a restart of the fleet view
	if f := NewStore(dir); true {
		list, err := f.Touches()
		if err != nil || len(list) != 3 || list[0].Verdict == "" {
			t.Fatalf("after a restart: %v %+v", err, list)
		}
	}
}

func TestTouchesPruned(t *testing.T) {
	s := NewStore(t.TempDir())
	now := time.Now()
	old := []Touch{
		{ID: "a", At: now.Add(-100 * 24 * time.Hour)},
		{ID: "b", At: now.Add(-100 * 24 * time.Hour), Verdict: "dealt"},
		{ID: "c", At: now.Add(-400 * 24 * time.Hour), Verdict: "dealt"},
		{ID: "d", At: now.Add(-time.Hour)},
	}
	if err := s.UpdateTouches(now, func([]Touch) ([]Touch, error) { return old, nil }); err != nil {
		t.Fatal(err)
	}
	list, _ := s.Touches()
	if len(list) != 2 || list[0].ID != "d" || list[1].ID != "b" {
		t.Fatalf("kept: %+v", list)
	}
}

func TestOriginWords(t *testing.T) {
	for ip, want := range map[string]string{"127.0.0.1": "the server itself", "172.18.0.4": "a private address", "100.70.1.2": "carrier", "198.51.100.7": "examples and tests"} {
		if o := lookupOrigin(context.Background(), ip); !strings.Contains(o.Private, want) {
			t.Fatalf("%s: %+v", ip, o)
		}
	}
	if got := cymruName(net.ParseIP("1.2.3.4")); got != "4.3.2.1.origin.asn.cymru.com" {
		t.Fatal(got)
	}
	if got := cymruName(net.ParseIP("2001:db9::1")); !strings.HasPrefix(got, "1.0.0.0.") || !strings.HasSuffix(got, ".9.b.d.0.1.0.0.2.origin6.asn.cymru.com") {
		t.Fatal(got)
	}
	for agent, want := range map[string]string{"": "didn't say", "curl/8.5": "curl", "Mozilla/5.0 (compatible; CensysInspect/1.1)": "Censys",
		"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36": "Chrome", "Go-http-client/1.1": "Go"} {
		if got := toolOf(agent); !strings.Contains(got, want) {
			t.Fatalf("%q: %s", agent, got)
		}
	}
}
