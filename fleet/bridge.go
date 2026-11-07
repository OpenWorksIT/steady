// The community, run from the fleet view (docs/COMMUNITY.md, "Practices from the fleet view").
//
// The fleet view keeps which practices are in the community (community-practices.json) and
// writes the sign-in bridge's list of them (bridge/practices.json, the only file the bridge
// reads from here): each practice's id, name, address, key, and the staff OpenWorks approved.
// A dev turns a practice on over SSH: the fleet view makes its key and hands it to the server
// with the fleet key (POST /api/steady/fleet/community), so no key is copied by hand and no
// .env line is needed. The practice's master psychologist puts staff in (Settings > Practice >
// Community); each new name waits here for a dev to approve. Someone the practice takes out
// comes off the bridge's list at the next poll, without anyone doing anything.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// CommunityPractice is one practice in the community, as the fleet view runs it.
type CommunityPractice struct {
	ID        string   `json:"id"` // the server's short name ("vr"): the forum's external ids start with it
	Name      string   `json:"name"`
	URL       string   `json:"url"`
	Key       string   `json:"key"`
	OpenWorks bool     `json:"openworks,omitempty"` // OpenWorks' own server: OpenWorks support comes in here
	Groups    []string `json:"groups,omitempty"`    // a practice's private forum group (setup.py --practice)
	Approved  []string `json:"approved"`            // the staff addresses OpenWorks approved
}

// CommunityPractices is community-practices.json.
type CommunityPractices struct {
	Practices map[string]*CommunityPractice `json:"practices"`
}

// bridgePractice is one entry of bridge/practices.json, in the bridge's own format
// (community/signin/config.go, Practice).
type bridgePractice struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	URL     string   `json:"url"`
	Key     string   `json:"key"`
	Emails  []string `json:"emails"`
	Groups  []string `json:"groups,omitempty"`
	Support bool     `json:"support,omitempty"`
}

// withCommunity reads community-practices.json, lets fn change it, and writes it and the
// bridge's list back, with a lock on the folder: the website (taking people out at each poll)
// and a dev's command may both change it.
func (s *Store) withCommunity(fn func(*CommunityPractices) (bool, error)) error {
	lock, err := os.OpenFile(s.path("community.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	var cp CommunityPractices
	if err := readJSON(s.path("community-practices.json"), &cp); err != nil {
		return fmt.Errorf("community-practices.json: %w", err)
	}
	if cp.Practices == nil {
		cp.Practices = map[string]*CommunityPractice{}
	}
	changed, err := fn(&cp)
	if err != nil || !changed {
		return err
	}
	if err := writeJSON(s.path("community-practices.json"), cp); err != nil {
		return err
	}
	return s.writeBridge(&cp)
}

// CommunityPractices: what the fleet view runs (read only).
func (s *Store) CommunityPractices() (*CommunityPractices, error) {
	var cp CommunityPractices
	if err := readJSON(s.path("community-practices.json"), &cp); err != nil {
		return nil, err
	}
	if cp.Practices == nil {
		cp.Practices = map[string]*CommunityPractice{}
	}
	return &cp, nil
}

// writeBridge: the bridge's list, in its own format, sorted so it changes only when something
// does. The bridge rereads it within seconds. A practice with nobody approved yet is left out:
// nobody could come in through it, and the bridge refuses a practice without addresses, which
// would set aside the whole list (every other practice with it).
func (s *Store) writeBridge(cp *CommunityPractices) error {
	if err := os.MkdirAll(s.path("bridge"), 0o700); err != nil {
		return err
	}
	out := []bridgePractice{}
	ids := make([]string, 0, len(cp.Practices))
	for id := range cp.Practices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		p := cp.Practices[id]
		if len(p.Approved) == 0 {
			continue
		}
		emails := append([]string{}, p.Approved...)
		sort.Strings(emails)
		out = append(out, bridgePractice{ID: p.ID, Name: p.Name, URL: p.URL, Key: p.Key, Emails: emails, Groups: p.Groups, Support: p.OpenWorks})
	}
	return writeJSON(filepath.Join(s.path("bridge"), "practices.json"), out)
}

func newCommunityKey() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// Member is a staff member a practice has put in the community (from its status).
type Member struct {
	Email, Name, Role string
}

// communityOf: what a server's status says about its community.
func communityOf(d map[string]any) (on, fleet bool, members []Member) {
	c, _ := d["community"].(map[string]any)
	if c == nil {
		return false, false, nil
	}
	on, _ = c["on"].(bool)
	fleet, _ = c["fleet"].(bool)
	list, _ := c["members"].([]any)
	for _, x := range list {
		m, _ := x.(map[string]any)
		email := strings.ToLower(strings.TrimSpace(str(m["email"])))
		if email == "" || !strings.Contains(email, "@") {
			continue
		}
		members = append(members, Member{Email: clip(email, 200), Name: clip(str(m["name"]), 80), Role: clip(str(m["role"]), 20)})
	}
	return on, fleet, members
}

// reconcile: someone the practice took out comes off the approved list (and so off the
// bridge's). Called after each poll, only with a status the server just gave.
func (s *Store) reconcile(sv Server, d map[string]any) {
	on, _, members := communityOf(d)
	if !on || d["community"] == nil {
		return
	}
	listed := map[string]bool{}
	for _, m := range members {
		listed[m.Email] = true
	}
	var gone []string
	err := s.withCommunity(func(cp *CommunityPractices) (bool, error) {
		p := cp.Practices[sv.ShortName()]
		if p == nil {
			return false, nil
		}
		keep := p.Approved[:0]
		for _, e := range p.Approved {
			if listed[e] {
				keep = append(keep, e)
			} else {
				gone = append(gone, e)
			}
		}
		p.Approved = keep
		return len(gone) > 0, nil
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleet: community:", err)
		return
	}
	for _, e := range gone {
		s.Audit("fleet view", "", "community out", sv.Name+": "+e+" (taken out by the practice)")
	}
}

// Pending: members the practice put in that OpenWorks hasn't approved yet.
func pending(p *CommunityPractice, members []Member) []Member {
	ok := map[string]bool{}
	if p != nil {
		for _, e := range p.Approved {
			ok[e] = true
		}
	}
	var out []Member
	for _, m := range members {
		if !ok[m.Email] {
			out = append(out, m)
		}
	}
	return out
}
