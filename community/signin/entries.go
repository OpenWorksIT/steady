// Sign-ins under way: who Steady said is coming, held for two minutes until the forum asks.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"sync"
	"time"
)

// entry is one person on their way from Steady's Community tab to the forum.
type entry struct {
	note     note
	practice string // the practice whose key signed the note
	client   string // the address it came from (for the per-address limit)
	created  time.Time
}

var errTooMany = errors.New("too many sign-ins under way from this address")

// Entries holds the sign-ins under way, each for ttl and used once, and the notes already used
// (by their jti), so a note can't be used twice. A restart forgets them: the tab just opens
// the community again.
type Entries struct {
	mu     sync.Mutex
	m      map[string]*entry
	used   map[string]time.Time
	ttl    time.Duration
	max    int
	perIP  int
	now    func() time.Time
	random func([]byte) (int, error)
}

func NewEntries(ttl time.Duration, max, perIP int) *Entries {
	return &Entries{m: map[string]*entry{}, used: map[string]time.Time{}, ttl: ttl, max: max, perIP: perIP, now: time.Now, random: rand.Read}
}

func (s *Entries) sweep(now time.Time) {
	for id, e := range s.m {
		if now.Sub(e.created) > s.ttl {
			delete(s.m, id)
		}
	}
	for j, until := range s.used {
		if now.After(until) {
			delete(s.used, j)
		}
	}
}

// Add records a checked note and returns the id its browser carries to the forum and back. A
// note's jti is taken until the note would have run out anyway.
func (s *Entries) Add(n note, practice, client string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.sweep(now)
	if _, seen := s.used[n.Jti]; seen {
		return "", errUsed
	}
	count := 0
	var oldest string
	for id, e := range s.m {
		if e.client == client {
			count++
		}
		if oldest == "" || e.created.Before(s.m[oldest].created) {
			oldest = id
		}
	}
	if count >= s.perIP {
		return "", errTooMany
	}
	if len(s.m) >= s.max {
		delete(s.m, oldest) // full: the oldest gives way (it has had its chance)
	}
	b := make([]byte, 32)
	if _, err := s.random(b); err != nil {
		return "", err
	}
	id := base64.RawURLEncoding.EncodeToString(b)
	s.m[id] = &entry{note: n, practice: practice, client: client, created: now}
	s.used[n.Jti] = time.Unix(n.Exp, 0).Add(clockSlack)
	return id, nil
}

// Take uses a sign-in up: it can't be used again.
func (s *Entries) Take(id string) (entry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.m[id]
	delete(s.m, id)
	if e == nil || s.now().Sub(e.created) > s.ttl {
		return entry{}, false
	}
	return *e, true
}

var errUsed = errors.New("this note was used already")
