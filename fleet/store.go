// The fleet view's files, in its data folder (FLEET_DATA, /data in the container):
//
//	servers.json  the practice servers: name, address and their two keys
//	users.json    who may sign in (password hashes and authenticator secrets)
//	audit.log     sign-ins and every action, one JSON line each
//	todo.json     OpenWorks' to-do list and the monthly upkeep round (todo.go)
//
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Server is one practice's Steady server.
// Its fleet key (STEADY_FLEET_KEY) reads the server's state and asks for a check, an update or
// a restart; nothing else.
type Server struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	FleetKey string `json:"fleetKey"`
}

type Store struct {
	dir string
	mu  sync.Mutex
	// todo.json (todo.go)
	todoMu sync.Mutex
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
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(append(b, '\n'))
	cerr := f.Close()
	if werr != nil || cerr != nil {
		os.Remove(tmp)
		return errors.Join(werr, cerr)
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// lockUsers holds an exclusive lock on users.json (users.lock) for the fleet view and the
// command line alike, so their read-change-write steps never overlap.
func (s *Store) lockUsers() (func(), error) {
	s.mu.Lock()
	f, err := os.OpenFile(s.path("users.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		s.mu.Unlock()
		return nil, err
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		s.mu.Unlock()
	}, nil
}

func (s *Store) Users() ([]User, error) {
	unlock, err := s.lockUsers()
	if err != nil {
		return nil, err
	}
	defer unlock()
	var u []User
	return u, readJSON(s.path("users.json"), &u)
}

// UpdateUsers reads users.json, lets change() edit the list and writes it back, all under the lock.
func (s *Store) UpdateUsers(change func([]User) ([]User, error)) error {
	unlock, err := s.lockUsers()
	if err != nil {
		return err
	}
	defer unlock()
	var u []User
	if err := readJSON(s.path("users.json"), &u); err != nil {
		return err
	}
	u, err = change(u)
	if err != nil {
		return err
	}
	return writeJSON(s.path("users.json"), u)
}

func (s *Store) SaveUsers(u []User) error {
	return s.UpdateUsers(func([]User) ([]User, error) { return u, nil })
}

// sameName compares names as given to the fleet view: plain ASCII, any case.
func sameName(a, b string) bool { return strings.ToLower(a) == strings.ToLower(b) }

func (s *Store) User(name string) (*User, error) {
	all, err := s.Users()
	if err != nil {
		return nil, err
	}
	for i := range all {
		if sameName(all[i].Name, name) {
			return &all[i], nil
		}
	}
	return nil, nil
}

// UseCode checks a user's authenticator code and marks its step used, in one locked step, so
// two sign-ins can't both use the same code.
func (s *Store) UseCode(name, code string, now time.Time) (bool, error) {
	ok := false
	err := s.UpdateUsers(func(all []User) ([]User, error) {
		for i := range all {
			if sameName(all[i].Name, name) {
				if step := TOTPCheck(&all[i], code, now); step > 0 {
					all[i].LastStep = step
					ok = true
				}
			}
		}
		return all, nil
	})
	return ok, err
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
	// plain http only to this machine itself (local tests)
	if err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && u.Hostname() == "127.0.0.1")) {
		return errors.New("the address must be https://<domain>")
	}
	if len(sv.FleetKey) < 24 {
		return errors.New("fleetKey is missing or short")
	}
	return nil
}

func clip(v string, n int) string {
	v = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, v)
	if len(v) > n {
		v = v[:n] + "…"
	}
	return v
}

// Audit appends one line to audit.log (moved to audit.log.1 past 5 MB). Failing to write it is
// reported, not fatal.
func (s *Store) Audit(who, ip, what, detail string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	path := s.path("audit.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "audit:", err)
		return
	}
	defer f.Close()
	line, _ := json.Marshal(map[string]string{"at": time.Now().UTC().Format(time.RFC3339), "who": clip(who, 40), "ip": clip(ip, 64), "what": clip(what, 40), "detail": clip(detail, 300)})
	f.Write(append(line, '\n'))
}

// RecentAudit is the last n lines, newest first (read from the file's last 256 KB).
func (s *Store) RecentAudit(n int) []map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := os.Open(s.path("audit.log"))
	if err != nil {
		return nil
	}
	defer f.Close()
	const tail = 256 << 10
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		f.Seek(st.Size()-tail, io.SeekStart)
	}
	b, _ := io.ReadAll(f)
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
