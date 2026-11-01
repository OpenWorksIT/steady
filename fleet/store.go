// The fleet view's files, in its data folder (FLEET_DATA, /data in the container):
//
//	servers.json  the practice servers: name, address and their two keys
//	users.json    who may sign in (password hashes and authenticator secrets)
//	audit.log     sign-ins and every action, one JSON line each
//
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Server is one practice's Steady server.
type Server struct {
	Name       string `json:"name"`
	URL        string `json:"url"`
	MonitorKey string `json:"monitorKey"`
	FleetKey   string `json:"fleetKey,omitempty"`
}

type Store struct {
	dir string
	mu  sync.Mutex
}

func NewStore(dir string) *Store { return &Store{dir: dir} }

func (s *Store) path(name string) string { return filepath.Join(s.dir, name) }

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// writeJSON replaces a file in one step, readable only by the service.
func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) Users() ([]User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var u []User
	return u, readJSON(s.path("users.json"), &u)
}

func (s *Store) SaveUsers(u []User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return writeJSON(s.path("users.json"), u)
}

func (s *Store) User(name string) (*User, error) {
	all, err := s.Users()
	if err != nil {
		return nil, err
	}
	for i := range all {
		if strings.EqualFold(all[i].Name, name) {
			return &all[i], nil
		}
	}
	return nil, nil
}

// UseStep records the TOTP step a user just signed in with, so the same code can't be used again.
func (s *Store) UseStep(name string, step int64) error {
	all, err := s.Users()
	if err != nil {
		return err
	}
	for i := range all {
		if strings.EqualFold(all[i].Name, name) {
			all[i].LastStep = step
		}
	}
	return s.SaveUsers(all)
}

func (s *Store) Servers() ([]Server, error) {
	var v []Server
	if err := readJSON(s.path("servers.json"), &v); err != nil {
		return nil, err
	}
	for _, sv := range v {
		if err := checkServer(sv); err != nil {
			return nil, fmt.Errorf("servers.json: %s: %w", sv.Name, err)
		}
	}
	return v, nil
}

func checkServer(sv Server) error {
	u, err := url.Parse(sv.URL)
	if err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && strings.HasPrefix(u.Host, "127.0.0.1"))) {
		return errors.New("the address must be https://<domain>")
	}
	if len(sv.MonitorKey) < 24 {
		return errors.New("monitorKey is missing or short")
	}
	if sv.FleetKey != "" && len(sv.FleetKey) < 24 {
		return errors.New("fleetKey is short")
	}
	return nil
}

// Audit appends one line to audit.log. Failing to write it is reported, not fatal.
func (s *Store) Audit(who, ip, what, detail string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := os.OpenFile(s.path("audit.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "audit:", err)
		return
	}
	defer f.Close()
	line, _ := json.Marshal(map[string]string{"at": time.Now().UTC().Format(time.RFC3339), "who": who, "ip": ip, "what": what, "detail": detail})
	f.Write(append(line, '\n'))
}

// RecentAudit is the last n lines, newest first.
func (s *Store) RecentAudit(n int) []map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := os.ReadFile(s.path("audit.log"))
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	var out []map[string]string
	for i := len(lines) - 1; i >= 0 && len(out) < n; i-- {
		var m map[string]string
		if json.Unmarshal([]byte(lines[i]), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}
