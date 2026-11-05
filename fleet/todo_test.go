// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func csrfOf(t *testing.T, page string) string {
	t.Helper()
	i := strings.Index(page, `name="csrf" value="`)
	if i < 0 {
		t.Fatal("no csrf on the page")
	}
	v := page[i+len(`name="csrf" value="`):]
	return v[:strings.Index(v, `"`)]
}

func readTodos(t *testing.T, dir string) TodoFile {
	t.Helper()
	var f TodoFile
	if err := readJSON(dir+"/todo.json", &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestTodoSeed(t *testing.T) {
	now := time.Date(2026, 11, 3, 14, 0, 0, 0, time.UTC)
	f, err := seedTodos(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Items) < 10 || f.Next != len(f.Items)+1 {
		t.Fatalf("seed: %d items, next %d", len(f.Items), f.Next)
	}
	for i, it := range f.Items {
		if it.ID != i+1 || it.Created.By == "" || it.check() != "" {
			t.Fatalf("seed item %d: %+v %q", i, it, it.check())
		}
	}
}

func TestTodoListStartsFromTheFirstList(t *testing.T) {
	_, site, _, u, dir := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/todo")
	page := body(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("todo: %d", res.StatusCode)
	}
	for _, want := range []string{`<a href="/todo">To do</a>`, "Release 1.1.0", "Firebase for Android notifications",
		`href="/checks">1 to fix, 3 to look at`, "0 of 33 confirmed", `<option>VR Clinical Psychology</option>`,
		`<h2 class="pri now">Now`, `<h2 class="pri soon">Soon`, `<h2 class="pri later">Later`} {
		if !strings.Contains(page, want) {
			t.Fatalf("todo page lacks %q", want)
		}
	}
	if strings.Index(page, `class="pri now"`) > strings.Index(page, `class="pri later"`) {
		t.Fatal("not ordered now, soon, later")
	}
	st, err := os.Stat(dir + "/todo.json")
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("todo.json: %v %v", err, st)
	}
	// filtered: only what's to look at
	res, _ = c.Get(site.URL + "/todo?status=look")
	page = body(t, res)
	if !strings.Contains(page, "Release 1.1.0") || strings.Contains(page, "Firebase for Android") {
		t.Fatal("status filter")
	}
	res, _ = c.Get(site.URL + "/todo?area=Paperwork")
	page = body(t, res)
	if !strings.Contains(page, "for Kempie") || strings.Contains(page, "Release 1.1.0") {
		t.Fatal("area filter")
	}
}

func TestTodoAddChangeAndConfirm(t *testing.T) {
	_, site, _, u, dir := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/todo")
	csrf := csrfOf(t, body(t, res))
	next := readTodos(t, dir).Next

	res, _ = c.PostForm(site.URL+"/todo", url.Values{"csrf": {csrf}, "title": {"Renew <b>the</b>  certificate"},
		"detail": {"line one\r\nline two\x07"}, "area": {"VR Clinical Psychology"}, "priority": {"now"}, "status": {"todo"},
		"due": {"2026-01-10"}, "link": {"https://example.com/x"}})
	if res.StatusCode != http.StatusSeeOther || !strings.HasSuffix(res.Header.Get("Location"), "#t"+strconv.Itoa(next)) {
		t.Fatalf("add: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	body(t, res)
	f := readTodos(t, dir)
	it := f.find(next)
	if it == nil || it.Title != "Renew <b>the</b> certificate" || it.Detail != "line one\nline two" || it.Created.By != "jane" || it.Status != "todo" {
		t.Fatalf("added: %+v", it)
	}
	res, _ = c.Get(site.URL + "/todo")
	page := body(t, res)
	if !strings.Contains(page, "Renew &lt;b&gt;the&lt;/b&gt; certificate") || strings.Contains(page, "<b>the</b>") {
		t.Fatal("not escaped")
	}
	if !strings.Contains(page, `class="overdue">by Sat 10 Jan</span>`) {
		t.Fatal("a date in the past isn't shown as past")
	}

	item := site.URL + "/todo/" + strconv.Itoa(next)
	post := func(v url.Values) string {
		v.Set("csrf", csrf)
		res, _ := c.PostForm(item, v)
		if res.StatusCode != http.StatusSeeOther {
			t.Fatalf("%v: %d %s", v, res.StatusCode, body(t, res))
		}
		body(t, res)
		res, _ = c.Get(item)
		return body(t, res)
	}
	page = post(url.Values{"op": {"status"}, "to": {"look"}, "note": {"asked Shap"}})
	if !strings.Contains(page, "On the list → To look at: asked Shap") || !strings.Contains(page, "Now to look at.") {
		t.Fatal("status change not in the history")
	}
	page = post(url.Values{"op": {"status"}, "to": {"look"}})
	if !strings.Contains(page, "It&#39;s already to look at.") {
		t.Fatal("same status again")
	}
	page = post(url.Values{"op": {"edit"}, "title": {"Renew the certificate"}, "detail": {"line one\nline two"}, "area": {"VR Clinical Psychology"},
		"priority": {"later"}, "due": {""}, "waiting": {"Shap"}, "link": {"https://example.com/x"}})
	if !strings.Contains(page, "Changed title &#34;Renew the certificate&#34;; priority Now → Later; date Sat 10 Jan → none; waiting on Shap") {
		t.Fatalf("edit not in the history: %s", page[strings.Index(page, "<h2>History"):])
	}
	page = post(url.Values{"op": {"status"}, "to": {"note"}, "note": {"Shap says Friday"}})
	if !strings.Contains(page, "Note: Shap says Friday") {
		t.Fatal("note")
	}
	page = post(url.Values{"op": {"status"}, "to": {"done"}, "note": {"renewed until 2027"}})
	it = todoOf(t, dir, next)
	if it.Status != "done" || it.Closed == nil || it.Closed.By != "jane" || it.Closed.Text != "renewed until 2027" {
		t.Fatalf("done: %+v", it)
	}
	if !strings.Contains(page, "Done: #"+strconv.Itoa(next)+", confirmed by jane.") || strings.Contains(page, `<button name="to" value="done">`) {
		t.Fatal("done page")
	}
	// back on the list, and closed again by the quick button from the list
	page = post(url.Values{"op": {"status"}, "to": {"todo"}})
	if todoOf(t, dir, next).Closed != nil {
		t.Fatal("reopened but still closed")
	}
	res, _ = c.PostForm(item, url.Values{"csrf": {csrf}, "op": {"status"}, "to": {"done"}, "from": {"list"}})
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/todo#t"+strconv.Itoa(next) {
		t.Fatalf("quick done: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	body(t, res)
	res, _ = c.Get(site.URL + "/todo")
	if page = body(t, res); !strings.Contains(page, "Done in the last 30 days") || !strings.Contains(page, "jane, ") {
		t.Fatal("not under done")
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	for _, want := range []string{`"detail":"#` + strconv.Itoa(next) + ` added: Renew`, `"what":"to-do"`, `To look at → Done: renewed until 2027`} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("audit log lacks %q", want)
		}
	}
}

func TestTodoRefusesWhatIsWrong(t *testing.T) {
	_, site, _, u, dir := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/todo")
	csrf := csrfOf(t, body(t, res))
	before := len(readTodos(t, dir).Items)
	good := func() url.Values {
		return url.Values{"csrf": {csrf}, "title": {"A thing"}, "detail": {"keep what I typed"}, "area": {"OpenWorks"}, "priority": {"soon"}, "status": {"todo"}}
	}
	for _, c2 := range []struct{ field, value, msg string }{
		{"title", "", "Give it a title."},
		{"title", strings.Repeat("x", 121), "The title is longer than 120 characters."},
		{"detail", strings.Repeat("x", 2001), "What needs to happen is longer than 2000 characters."},
		{"priority", "urgent", "Choose now, soon or later."},
		{"area", "", "Choose where it belongs."},
		{"due", "2026-13-40", "The date isn&#39;t a date."},
		{"due", "10/11/2026", "The date isn&#39;t a date."},
		{"link", "javascript:alert(1)", "The link must be an https:// address."},
		{"link", "http://example.com", "The link must be an https:// address."},
		{"link", "https://user:pw@example.com", "The link must be an https:// address."},
	} {
		v := good()
		v.Set(c2.field, c2.value)
		res, _ := c.PostForm(site.URL+"/todo", v)
		page := body(t, res)
		if res.StatusCode != http.StatusBadRequest || !strings.Contains(page, c2.msg) {
			t.Fatalf("%s=%q: %d, wanted %q", c2.field, c2.value, res.StatusCode, c2.msg)
		}
		if c2.field != "detail" && !strings.Contains(page, ">keep what I typed</textarea>") {
			t.Fatalf("%s: what was typed is gone", c2.field)
		}
	}
	if n := len(readTodos(t, dir).Items); n != before {
		t.Fatalf("added anyway: %d → %d", before, n)
	}
	// longer forms than the sign-in's are fine here
	v := good()
	v.Set("detail", strings.Repeat("é", 1900))
	if res, _ := c.PostForm(site.URL+"/todo", v); res.StatusCode != http.StatusSeeOther {
		t.Fatalf("a long detail: %d", res.StatusCode)
	}
	// no form without its token, no item that isn't there
	v = good()
	v.Del("csrf")
	if res, _ := c.PostForm(site.URL+"/todo", v); res.StatusCode != http.StatusForbidden {
		t.Fatalf("no csrf: %d", res.StatusCode)
	}
	for _, p := range []string{"/todo/999", "/todo/abc", "/todo/0", "/todo/-1"} {
		if res, _ := c.Get(site.URL + p); res.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: %d", p, res.StatusCode)
		}
	}
	if res, _ := c.PostForm(site.URL+"/todo/999", url.Values{"csrf": {csrf}, "op": {"status"}, "to": {"done"}}); res.StatusCode != http.StatusNotFound {
		t.Fatalf("post to a missing item: %d", res.StatusCode)
	}
	// an edit that's wrong is shown again with the error, and changes nothing
	res, _ = c.PostForm(site.URL+"/todo/1", url.Values{"csrf": {csrf}, "op": {"edit"}, "title": {"x"}, "area": {"OpenWorks"}, "priority": {"soon"}, "link": {"ftp://x"}})
	if page := body(t, res); res.StatusCode != http.StatusBadRequest || !strings.Contains(page, "The link must be") || !strings.Contains(page, "<details open>") {
		t.Fatalf("bad edit: %d", res.StatusCode)
	}
	if todoOf(t, dir, 1).Title == "x" {
		t.Fatal("bad edit saved")
	}
	// signed out: nothing
	if res, _ := client().Get(site.URL + "/todo"); res.StatusCode != http.StatusSeeOther {
		t.Fatalf("signed out: %d", res.StatusCode)
	}
}

func TestUpkeepConfirmAndTakeBack(t *testing.T) {
	_, site, _, u, dir := setup(t)
	c := signIn(t, site, u, time.Now())
	res, _ := c.Get(site.URL + "/upkeep")
	page := body(t, res)
	month := monthKey(time.Now())
	if !strings.Contains(page, "Upkeep for "+monthName(month)) || !strings.Contains(page, "<strong>0 of 33</strong> confirmed") {
		t.Fatal("upkeep page")
	}
	csrf := csrfOf(t, page)
	post := func(month, key, op string) int {
		res, _ := c.PostForm(site.URL+"/upkeep", url.Values{"csrf": {csrf}, "month": {month}, "key": {key}, "op": {op}})
		body(t, res)
		return res.StatusCode
	}
	if post(month, "srv-tls", "confirm") != http.StatusSeeOther || post(month, "srv-tls", "confirm") != http.StatusSeeOther {
		t.Fatal("confirm")
	}
	res, _ = c.Get(site.URL + "/upkeep")
	page = body(t, res)
	if !strings.Contains(page, "<strong>1 of 33</strong> confirmed") || !strings.Contains(page, "confirmed</span> jane, ") || !strings.Contains(page, `value="undo"`) {
		t.Fatal("not confirmed")
	}
	res, _ = c.Get(site.URL + "/todo")
	if !strings.Contains(body(t, res), "1 of 33 confirmed") {
		t.Fatal("the list doesn't show the upkeep")
	}
	if e := readTodos(t, dir).Upkeep[month]["srv-tls"]; e.By != "jane" {
		t.Fatalf("stored: %+v", e)
	}
	post(month, "srv-tls", "undo")
	if len(readTodos(t, dir).Upkeep[month]) != 0 {
		t.Fatal("not taken back")
	}
	last := time.Now().In(sast).AddDate(0, -1, 0)
	if last.Year() >= 2026 && post(monthKey(last), "own-key", "confirm") != http.StatusSeeOther {
		t.Fatal("last month")
	}
	next := time.Now().In(sast).AddDate(0, 1, 0)
	for _, bad := range [][3]string{{month, "nope", "confirm"}, {monthKey(next), "own-key", "confirm"}, {"", "own-key", "confirm"},
		{"2025-12", "own-key", "confirm"}, {"2026-1", "own-key", "confirm"}, {month, "own-key", "delete"}} {
		if code := post(bad[0], bad[1], bad[2]); code != http.StatusBadRequest {
			t.Fatalf("%v: %d", bad, code)
		}
	}
	b, _ := os.ReadFile(dir + "/audit.log")
	if !strings.Contains(string(b), month+" srv-tls confirmed") || !strings.Contains(string(b), month+" srv-tls taken back") {
		t.Fatal("upkeep not in the audit log")
	}
}

func TestTodoPage(t *testing.T) {
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	at := func(d int) time.Time { return now.AddDate(0, 0, -d) }
	f := TodoFile{Items: []Todo{
		{ID: 1, Title: "later, no date", Area: "GitHub", Priority: "later", Status: "todo"},
		{ID: 2, Title: "soon, due later", Area: "Paperwork", Priority: "soon", Status: "look", Due: "2026-12-01"},
		{ID: 3, Title: "soon, past", Area: "Paperwork", Priority: "soon", Status: "waiting", Due: "2026-11-19", Waiting: "lawyer"},
		{ID: 4, Title: "soon, no date", Area: "Paperwork", Priority: "soon", Status: "todo"},
		{ID: 5, Title: "done lately", Area: "GitHub", Priority: "now", Status: "done", Changed: at(3), Closed: &Entry{At: at(3), By: "jane"}},
		{ID: 6, Title: "done long ago", Area: "GitHub", Priority: "now", Status: "done", Changed: at(40), Closed: &Entry{At: at(40), By: "jane"}},
	}}
	p := makeTodoPage(f, "", "", []string{"VR"}, now)
	if len(p.Groups) != 2 || p.Groups[0].Key != "soon" || p.Groups[1].Key != "later" {
		t.Fatalf("groups: %+v", p.Groups)
	}
	if g := p.Groups[0].Rows; g[0].ID != 3 || g[1].ID != 2 || g[2].ID != 4 || !g[0].Overdue || g[1].Overdue {
		t.Fatalf("soon: %+v", g)
	}
	if p.Open != 4 || p.Look != 1 || p.Waiting != 1 || p.Overdue != 1 || p.Now != 0 {
		t.Fatalf("counts: %+v", p)
	}
	if len(p.Closed) != 1 || p.Closed[0].ID != 5 {
		t.Fatalf("closed: %+v", p.Closed)
	}
	if p := makeTodoPage(f, "done", "", nil, now); len(p.Closed) != 2 || len(p.Groups) != 0 {
		t.Fatal("all that's done")
	}
	if p := makeTodoPage(f, "", "GitHub", nil, now); len(p.Groups) != 1 || p.Groups[0].Rows[0].ID != 1 || p.Open != 4 {
		t.Fatal("area")
	}
	if p.Areas[len(p.Areas)-1] != "VR" || len(p.AreaChips) != 3 {
		t.Fatalf("areas: %v %v", p.Areas, p.AreaChips)
	}
	if v, ok := lines("a\x00b\n\n\n\n\nc\r\nd", 100); !ok || v != "ab\n\n\nc\nd" {
		t.Fatalf("lines: %q", v)
	}
	if v, ok := oneLine("  a\tb\n c​ ", 100); !ok || v != "a b c​" {
		t.Fatalf("oneLine: %q", v)
	}
}

func todoOf(t *testing.T, dir string, id int) *Todo {
	t.Helper()
	f := readTodos(t, dir)
	return f.find(id)
}
