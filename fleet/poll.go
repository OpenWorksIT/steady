// Asks every practice server for its state once a minute (GET /api/steady/fleet with its
// monitor key) and keeps the latest answer. Never anything about patients: the servers only
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
	store  *Store
	client *http.Client
	mu     sync.Mutex
	last   map[string]*Status // by URL
}

func NewPoller(store *Store) *Poller {
	return &Poller{store: store, client: &http.Client{Timeout: 15 * time.Second}, last: map[string]*Status{}}
}

func (p *Poller) fetch(ctx context.Context, sv Server) *Status {
	st := &Status{Server: sv, At: time.Now()}
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(sv.URL, "/")+"/api/steady/fleet", nil)
	if err != nil {
		st.Err = err.Error()
		return st
	}
	req.Header.Set("X-Steady-Monitor", sv.MonitorKey)
	t0 := time.Now()
	res, err := p.client.Do(req)
	st.Latency = time.Since(t0)
	if err != nil {
		st.Err = "can't reach the server: " + shortErr(err)
		return st
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode == 404 {
		st.Err = "the server doesn't know this monitor key (or runs a Steady older than 1.0.3)"
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
}

// Run polls now and then every interval until ctx ends.
func (p *Poller) Run(ctx context.Context, every time.Duration) {
	p.PollAll(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.PollAll(ctx)
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
	if sv.FleetKey == "" {
		return errors.New("this server has no fleet key in servers.json, so the fleet view can only look")
	}
	body, _ := json.Marshal(map[string]string{"action": action})
	req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(sv.URL, "/")+"/api/steady/fleet/request", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Steady-Fleet", sv.FleetKey)
	res, err := p.client.Do(req)
	if err != nil {
		return errors.New("can't reach the server: " + shortErr(err))
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	if res.StatusCode == 200 {
		return nil
	}
	var e struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(b, &e)
	if res.StatusCode == 404 {
		return errors.New("the server doesn't accept this fleet key")
	}
	if e.Message != "" {
		return errors.New(e.Message)
	}
	return fmt.Errorf("the server answered %d", res.StatusCode)
}
