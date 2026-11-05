// The To do pages: OpenWorks' list (/todo, /todo/{id}) and the monthly upkeep round (/upkeep).
// Every change is in the item's history and the audit log, with who made it.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var errFull = fmt.Errorf("the list holds %d items: remove some from todo.json first", maxItems)

// todoForm is what the add or edit form showed, to show it again with what was typed.
type todoForm struct {
	Title, Detail, Area, Priority, Status, Waiting, Due, Link string
	Error                                                     string
}

func formOf(t Todo) todoForm {
	return todoForm{Title: t.Title, Detail: t.Detail, Area: t.Area, Priority: t.Priority, Status: t.Status, Waiting: t.Waiting, Due: t.Due, Link: t.Link}
}

func (a *App) serverNames() []string {
	sts, _ := a.poller.Snapshot()
	names := make([]string, 0, len(sts))
	for _, st := range sts {
		names = append(names, st.Server.Name)
	}
	return names
}

func (a *App) todo(w http.ResponseWriter, r *http.Request, s *Session) {
	a.renderTodo(w, r, s, todoForm{Area: "OpenWorks", Priority: "soon", Status: "todo"}, http.StatusOK)
}

func (a *App) renderTodo(w http.ResponseWriter, r *http.Request, s *Session, form todoForm, code int) {
	now := a.now()
	f, err := a.store.Todos(now)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	qs := r.URL.Query()
	status := qs.Get("status")
	if label(statuses, status) == "" || status == "dropped" {
		status = ""
	}
	area, _ := oneLine(qs.Get("area"), 60)
	page := makeTodoPage(f, status, area, a.serverNames(), now)
	sts, _ := a.poller.Snapshot()
	ch := makeChecks(sts, now)
	page.Fix, page.ToLook = len(ch.Fix), len(ch.Look)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	a.render(w, "todo.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Page": page, "Form": form,
		"Statuses": statuses[:3], "Msg": a.sessions.TakeFlash(s)})
}

func (a *App) todoAdd(w http.ResponseWriter, r *http.Request, s *Session) {
	now := a.now()
	t := Todo{Status: r.PostFormValue("status")}
	if t.Status != "look" && t.Status != "waiting" {
		t.Status = "todo"
	}
	if msg := fromForm(r.PostFormValue, &t); msg != "" {
		form := formOf(t)
		form.Detail, form.Error = r.PostFormValue("detail"), msg
		a.renderTodo(w, r, s, form, http.StatusBadRequest)
		return
	}
	err := a.store.UpdateTodos(now, func(f *TodoFile) error {
		if len(f.Items) >= maxItems {
			return errFull
		}
		t.ID = f.Next
		f.Next++
		t.Created = Entry{At: now, By: s.User}
		t.Changed = now
		f.Items = append(f.Items, t)
		return nil
	})
	if err != nil {
		if !errors.Is(err, errFull) {
			err = errors.New("todo.json can't be written")
		}
		form := formOf(t)
		form.Error = "Not added: " + err.Error() + "."
		a.renderTodo(w, r, s, form, http.StatusInternalServerError)
		return
	}
	a.store.Audit(s.User, a.clientIP(r), "to-do", fmt.Sprintf("#%d added: %s", t.ID, t.Title))
	a.sessions.SetFlash(s, fmt.Sprintf("Added #%d, %s.", t.ID, t.Title))
	http.Redirect(w, r, "/todo#t"+strconv.Itoa(t.ID), http.StatusSeeOther)
}

func todoID(r *http.Request) (int, bool) {
	id, err := strconv.Atoi(r.PathValue("id"))
	return id, err == nil && id > 0
}

func (a *App) todoItem(w http.ResponseWriter, r *http.Request, s *Session) {
	a.renderItem(w, r, s, nil, http.StatusOK)
}

type histLine struct{ When, By, Text string }

func (a *App) renderItem(w http.ResponseWriter, r *http.Request, s *Session, edit *todoForm, code int) {
	id, ok := todoID(r)
	now := a.now()
	f, err := a.store.Todos(now)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var t *Todo
	if ok {
		t = f.find(id)
	}
	if t == nil {
		http.NotFound(w, r)
		return
	}
	form := formOf(*t)
	if edit != nil {
		form = *edit
	}
	// the areas offered, with this item's own first if it isn't one of them
	opts := append(append([]string{}, areas...), a.serverNames()...)
	known := false
	for _, o := range opts {
		known = known || o == form.Area
	}
	if !known && form.Area != "" {
		opts = append([]string{form.Area}, opts...)
	}
	hist := make([]histLine, 0, len(t.History)+1)
	for i := len(t.History) - 1; i >= 0; i-- {
		e := t.History[i]
		hist = append(hist, histLine{when(e.At, now), e.By, e.Text})
	}
	hist = append(hist, histLine{when(t.Created.At, now), t.Created.By, "Added"})
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	a.render(w, "todo_item.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Row": makeTodoRow(*t, now), "Form": form,
		"Areas": opts, "Priorities": priorities, "Statuses": statuses, "History": hist, "Msg": a.sessions.TakeFlash(s)})
}

func (a *App) todoChange(w http.ResponseWriter, r *http.Request, s *Session) {
	id, ok := todoID(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	now := a.now()
	back := "/todo/" + strconv.Itoa(id)
	var did, flash string
	var bad *todoForm
	found := false
	err := a.store.UpdateTodos(now, func(f *TodoFile) error {
		t := f.find(id)
		if t == nil {
			return nil
		}
		found = true
		switch r.PostFormValue("op") {
		case "status":
			did, flash = changeStatus(t, r, s.User, now)
		case "edit":
			n := *t
			if msg := fromForm(r.PostFormValue, &n); msg != "" {
				form := formOf(n)
				form.Detail, form.Error = r.PostFormValue("detail"), msg
				bad = &form
				return nil
			}
			did = changes(*t, n, now)
			if did == "" {
				flash = "Nothing changed."
				return nil
			}
			t.Title, t.Detail, t.Area, t.Priority, t.Due, t.Waiting, t.Link = n.Title, n.Detail, n.Area, n.Priority, n.Due, n.Waiting, n.Link
			t.log(now, s.User, did)
			flash = "Saved."
		default:
			flash = "That form wasn't one of this page's."
		}
		return nil
	})
	switch {
	case err != nil:
		a.sessions.SetFlash(s, "Not saved: todo.json can't be written.")
	case !found:
		http.NotFound(w, r)
		return
	case bad != nil:
		a.renderItem(w, r, s, bad, http.StatusBadRequest)
		return
	default:
		if did != "" {
			a.store.Audit(s.User, a.clientIP(r), "to-do", fmt.Sprintf("#%d %s", id, did))
		}
		a.sessions.SetFlash(s, flash)
	}
	if r.PostFormValue("from") == "list" {
		back = "/todo#t" + strconv.Itoa(id)
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}

// changeStatus: a new status, a note, or both. Done and "not doing" keep who closed it, when,
// and what they said. It returns what was done (for the history and the audit log) and what to
// tell the person.
func changeStatus(t *Todo, r *http.Request, user string, now time.Time) (string, string) {
	note, ok := lines(r.PostFormValue("note"), maxNote)
	if !ok {
		return "", fmt.Sprintf("The note is longer than %d characters: nothing saved.", maxNote)
	}
	to := r.PostFormValue("to")
	if to == "note" {
		if note == "" {
			return "", "Write the note first."
		}
		t.log(now, user, "Note: "+note)
		return "note: " + note, "Note added."
	}
	if label(statuses, to) == "" {
		return "", "That isn't a status."
	}
	if to == t.Status && note == "" {
		return "", "It's already " + strings.ToLower(label(statuses, to)) + "."
	}
	text := label(statuses, t.Status) + " → " + label(statuses, to)
	if to == t.Status {
		text = label(statuses, to)
	}
	t.Status = to
	if to == "waiting" && t.Waiting != "" {
		text += " (on " + t.Waiting + ")"
	}
	if isOpen(to) {
		t.Closed = nil
	} else {
		t.Closed = &Entry{At: now, By: user, Text: note}
	}
	if note != "" {
		text += ": " + note
	}
	t.log(now, user, text)
	tell := "Now " + strings.ToLower(label(statuses, to)) + "."
	switch to {
	case "done":
		tell = fmt.Sprintf("Done: #%d, confirmed by %s.", t.ID, user)
	case "dropped":
		tell = fmt.Sprintf("#%d is marked as not doing.", t.ID)
	}
	return text, tell
}

// changes lists what an edit changed, in words, or "".
func changes(old, n Todo, now time.Time) string {
	var out []string
	or := func(v, none string) string {
		if v == "" {
			return none
		}
		return v
	}
	due := func(v string) string {
		if v == "" {
			return "none"
		}
		d, _ := dueText(v, now)
		return d
	}
	if old.Title != n.Title {
		out = append(out, "title \""+n.Title+"\"")
	}
	if old.Detail != n.Detail {
		out = append(out, "what needs to happen")
	}
	if old.Area != n.Area {
		out = append(out, "area "+old.Area+" → "+n.Area)
	}
	if old.Priority != n.Priority {
		out = append(out, "priority "+label(priorities, old.Priority)+" → "+label(priorities, n.Priority))
	}
	if old.Due != n.Due {
		out = append(out, "date "+due(old.Due)+" → "+due(n.Due))
	}
	if old.Waiting != n.Waiting {
		out = append(out, "waiting on "+or(n.Waiting, "nobody"))
	}
	if old.Link != n.Link {
		out = append(out, "link "+or(n.Link, "removed"))
	}
	if len(out) == 0 {
		return ""
	}
	return "Changed " + strings.Join(out, "; ")
}

func (a *App) upkeep(w http.ResponseWriter, r *http.Request, s *Session) {
	now := a.now()
	month, ok := upkeepMonth(r.URL.Query().Get("month"), now)
	if !ok {
		http.Redirect(w, r, "/upkeep", http.StatusSeeOther)
		return
	}
	f, err := a.store.Todos(now)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	a.render(w, "upkeep.html", map[string]any{"User": s.User, "CSRF": s.CSRF, "Page": makeUpkeepPage(f, month, now), "Msg": a.sessions.TakeFlash(s)})
}

func (a *App) upkeepChange(w http.ResponseWriter, r *http.Request, s *Session) {
	now := a.now()
	month, ok := upkeepMonth(r.PostFormValue("month"), now)
	key, op := r.PostFormValue("key"), r.PostFormValue("op")
	if !ok || r.PostFormValue("month") == "" || !upkeepKnown(key) || (op != "confirm" && op != "undo") {
		http.Error(w, "That isn't an upkeep item of a month that can be changed.", http.StatusBadRequest)
		return
	}
	changed := false
	err := a.store.UpdateTodos(now, func(f *TodoFile) error {
		m := f.Upkeep[month]
		if m == nil {
			m = map[string]Entry{}
			f.Upkeep[month] = m
		}
		_, had := m[key]
		if op == "confirm" && !had {
			m[key] = Entry{At: now, By: s.User}
			changed = true
		} else if op == "undo" && had {
			delete(m, key)
			changed = true
		}
		if len(m) == 0 {
			delete(f.Upkeep, month)
		}
		return nil
	})
	if err != nil {
		a.sessions.SetFlash(s, "Not saved: todo.json can't be written.")
	} else if changed {
		what := "confirmed"
		if op == "undo" {
			what = "taken back"
		}
		a.store.Audit(s.User, a.clientIP(r), "upkeep", month+" "+key+" "+what)
	}
	http.Redirect(w, r, "/upkeep?"+url.Values{"month": {month}}.Encode()+"#u-"+key, http.StatusSeeOther)
}
