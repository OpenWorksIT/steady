// Asks every practice server for its state once a minute (GET /api/steady/fleet with its
// fleet key) and keeps the latest answer. Never anything about patients: the servers only
// send versions, health, counts and backup age.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Status is what one server last said, or why it couldn't be reached.
type Status struct {
	Server  Server
	At      time.Time
	Err     string
	Data    map[string]any
	Latency time.Duration
}

type Poller struct {
	store     *Store
	client    *http.Client
	mu        sync.Mutex
	last      map[string]*Status // by URL
	community *CommunityStatus   // nil: no community.json
}

func NewPoller(store *Store) *Poller {
	// never follow a redirect: the key would go along to wherever it points
	client := &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return &Poller{store: store, client: client, last: map[string]*Status{}}
}

func (p *Poller) fetch(ctx context.Context, sv Server) *Status {
	st := &Status{Server: sv, At: time.Now()}
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(sv.URL, "/")+"/api/steady/fleet", nil)
	if err != nil {
		st.Err = err.Error()
		return st
	}
	req.Header.Set("X-Steady-Fleet", sv.FleetKey)
	t0 := time.Now()
	res, err := p.client.Do(req)
	st.Latency = time.Since(t0)
	if err != nil {
		st.Err = "can't reach the server: " + shortErr(err)
		return st
	}
	defer res.Body.Close()
	// a server's status is a few kilobytes
	body, _ := io.ReadAll(io.LimitReader(res.Body, 256<<10))
	if res.StatusCode == 404 {
		st.Err = "the server doesn't know this fleet key (or runs a Steady older than 1.0.3)"
		return st
	}
	if res.StatusCode >= 300 && res.StatusCode < 400 {
		st.Err = "the server sent a redirect (not followed): check its address in servers.json"
		return st
	}
	if res.StatusCode != 200 {
		st.Err = fmt.Sprintf("the server answered %d", res.StatusCode)
		return st
	}
	if err := json.Unmarshal(body, &st.Data); err != nil {
		st.Err = "the server's answer wasn't readable"
	}
	return st
}

// shortErr keeps an error to its last part, without addresses that carry keys.
func shortErr(err error) string {
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 {
		s = s[i+2:]
	}
	return s
}

// PollAll asks every server, at the same time.
func (p *Poller) PollAll(ctx context.Context) {
	servers, err := p.store.Servers()
	if err != nil {
		p.mu.Lock()
		p.last["config"] = &Status{At: time.Now(), Err: err.Error()}
		p.mu.Unlock()
		return
	}
	var wg sync.WaitGroup
	results := make([]*Status, len(servers))
	for i, sv := range servers {
		wg.Add(1)
		go func(i int, sv Server) {
			defer wg.Done()
			results[i] = p.fetch(ctx, sv)
		}(i, sv)
	}
	wg.Wait()
	p.mu.Lock()
	p.last = map[string]*Status{}
	for _, st := range results {
		p.last[st.Server.URL] = st
	}
	p.mu.Unlock()
	// staff a practice took out of the community come off the bridge's list
	for _, st := range results {
		if st.Err == "" && st.Data != nil {
			p.store.reconcile(st.Server, st.Data)
		}
	}
}

// Status asks one server for its state now (GET /api/steady/fleet), for a dev's command.
func (p *Poller) Status(ctx context.Context, sv Server) *Status { return p.fetch(ctx, sv) }

// Run polls now and then every interval until ctx ends.
// The forum's counts are asked for every tenth time.
func (p *Poller) Run(ctx context.Context, every time.Duration) {
	p.PollAll(ctx)
	p.PollCommunity(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for n := 1; ; n++ {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.PollAll(ctx)
			if n%10 == 0 {
				p.PollCommunity(ctx)
			}
		}
	}
}

// Snapshot is the latest status of each configured server, in servers.json order.
func (p *Poller) Snapshot() ([]*Status, string) {
	servers, err := p.store.Servers()
	if err != nil {
		return nil, err.Error()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]*Status, 0, len(servers))
	for _, sv := range servers {
		if st, ok := p.last[sv.URL]; ok {
			out = append(out, st)
		} else {
			out = append(out, &Status{Server: sv, Err: "not checked yet"})
		}
	}
	return out, ""
}

// Request asks a server to check for updates, update or restart (POST /api/steady/fleet/request).
func (p *Poller) Request(ctx context.Context, sv Server, action string) error {
	_, err := p.post(ctx, sv, "/api/steady/fleet/request", map[string]any{"action": action})
	return err
}

// ResetResult: what a server answers to a staff password reset from the fleet.
type ResetResult struct {
	TemporaryPassword string `json:"temporaryPassword"`
	EmailedTo         string `json:"emailedTo"`
	TwoStepCleared    bool   `json:"twoStepCleared"`
	Account           struct {
		Name string `json:"name"`
		Role string `json:"role"`
	} `json:"account"`
}

// Reset asks a server to reset a staff member's password (POST /api/steady/fleet/reset). The
// person finishes it with the temporary password and a code the server emails them.
func (p *Poller) Reset(ctx context.Context, sv Server, email string, twoStep bool) (*ResetResult, error) {
	b, err := p.post(ctx, sv, "/api/steady/fleet/reset", map[string]any{"email": email, "twoStep": twoStep})
	if err != nil {
		return nil, err
	}
	var r ResetResult
	if json.Unmarshal(b, &r) != nil || r.TemporaryPassword == "" {
		return nil, errors.New("the server's answer isn't one it would give")
	}
	return &r, nil
}

// post sends one fleet request with the server's fleet key, and gives back the answer's body.
func (p *Poller) post(ctx context.Context, sv Server, path string, in map[string]any) ([]byte, error) {
	body, _ := json.Marshal(in)
	req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(sv.URL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Steady-Fleet", sv.FleetKey)
	res, err := p.client.Do(req)
	if err != nil {
		return nil, errors.New("can't reach the server: " + shortErr(err))
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 16384))
	if res.StatusCode == 200 {
		return b, nil
	}
	var e struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(b, &e)
	if res.StatusCode == 404 && e.Message == "Not found." {
		return nil, errors.New("the server doesn't accept this fleet key")
	}
	if e.Message != "" {
		return nil, errors.New(e.Message)
	}
	return nil, fmt.Errorf("the server answered %d", res.StatusCode)
}
