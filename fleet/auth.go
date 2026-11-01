// Sign-in for the fleet view: a password (PBKDF2-SHA256) and a code from an authenticator app
// (TOTP, RFC 6238), sessions in memory, and limits on wrong guesses.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	pbkdfIter    = 600000
	sessionIdle  = 30 * time.Minute
	sessionMax   = 8 * time.Hour
	failWindow   = 15 * time.Minute
	failsPerIP   = 8
	failsPerUser = 10
)

// User is one person allowed into the fleet view.
type User struct {
	Name     string `json:"name"`
	Salt     string `json:"salt"`
	Hash     string `json:"hash"`
	Iter     int    `json:"iter"`
	TOTP     string `json:"totp"`     // base32 secret
	LastStep int64  `json:"lastStep"` // the last TOTP step used, so a code works only once
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func hashPassword(password string, salt []byte, iter int) []byte {
	k, err := pbkdf2.Key(sha256.New, password, salt, iter, 32)
	if err != nil {
		panic(err)
	}
	return k
}

// NewUser makes a user with a fresh salt and TOTP secret.
func NewUser(name, password string) User {
	salt := randomBytes(16)
	return User{
		Name: name,
		Salt: base64.StdEncoding.EncodeToString(salt),
		Hash: base64.StdEncoding.EncodeToString(hashPassword(password, salt, pbkdfIter)),
		Iter: pbkdfIter,
		TOTP: strings.TrimRight(base32.StdEncoding.EncodeToString(randomBytes(20)), "="),
	}
}

// PasswordOK checks a password; a nil user still does the work, so timing doesn't tell
// whether a name exists.
func PasswordOK(u *User, password string) bool {
	if u == nil {
		hashPassword(password, []byte("no-such-user-pad"), pbkdfIter)
		return false
	}
	salt, err1 := base64.StdEncoding.DecodeString(u.Salt)
	want, err2 := base64.StdEncoding.DecodeString(u.Hash)
	if err1 != nil || err2 != nil || u.Iter < 1 {
		return false
	}
	return subtle.ConstantTimeCompare(hashPassword(password, salt, u.Iter), want) == 1
}

// totpAt is the 6-digit code for a time step.
func totpAt(secret string, step int64) (string, error) {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(strings.TrimRight(secret, "=")))
	if err != nil {
		return "", err
	}
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step))
	m := hmac.New(sha1.New, key)
	m.Write(msg[:])
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", v%1000000), nil
}

// TOTPCheck accepts the code for now or one step either side, never a step already used.
// Returns the step matched (0 when none).
func TOTPCheck(u *User, code string, now time.Time) int64 {
	code = strings.TrimSpace(code)
	if u == nil || len(code) != 6 {
		return 0
	}
	cur := now.Unix() / 30
	for _, step := range []int64{cur - 1, cur, cur + 1} {
		if step <= u.LastStep {
			continue
		}
		want, err := totpAt(u.TOTP, step)
		if err == nil && subtle.ConstantTimeCompare([]byte(want), []byte(code)) == 1 {
			return step
		}
	}
	return 0
}

// OTPAuthURI is what an authenticator app scans.
func OTPAuthURI(u User) string {
	label := url.PathEscape("Steady fleet:" + u.Name)
	return "otpauth://totp/" + label + "?secret=" + u.TOTP + "&issuer=" + url.QueryEscape("Steady fleet") + "&algorithm=SHA1&digits=6&period=30"
}

// Session is one signed-in browser.
type Session struct {
	User    string
	CSRF    string
	Started time.Time
	Seen    time.Time
}

// Sessions are kept in memory: a restart signs everyone out, which is fine for a few people.
type Sessions struct {
	mu sync.Mutex
	m  map[string]*Session
}

func NewSessions() *Sessions { return &Sessions{m: map[string]*Session{}} }

func (s *Sessions) New(user string, now time.Time) (string, *Session) {
	id := base64.RawURLEncoding.EncodeToString(randomBytes(32))
	ss := &Session{User: user, CSRF: base64.RawURLEncoding.EncodeToString(randomBytes(24)), Started: now, Seen: now}
	s.mu.Lock()
	s.m[id] = ss
	s.mu.Unlock()
	return id, ss
}

func (s *Sessions) Get(id string, now time.Time) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss := s.m[id]
	if ss == nil {
		return nil
	}
	if now.Sub(ss.Seen) > sessionIdle || now.Sub(ss.Started) > sessionMax {
		delete(s.m, id)
		return nil
	}
	ss.Seen = now
	return ss
}

func (s *Sessions) End(id string) {
	s.mu.Lock()
	delete(s.m, id)
	s.mu.Unlock()
}

// Limiter counts wrong sign-ins per address and per name.
type Limiter struct {
	mu    sync.Mutex
	fails map[string][]time.Time
}

func NewLimiter() *Limiter { return &Limiter{fails: map[string][]time.Time{}} }

func (l *Limiter) recent(key string, now time.Time) []time.Time {
	var keep []time.Time
	for _, t := range l.fails[key] {
		if now.Sub(t) < failWindow {
			keep = append(keep, t)
		}
	}
	l.fails[key] = keep
	return keep
}

// Blocked is true while an address or a name has too many recent failures.
func (l *Limiter) Blocked(ip, user string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent("ip:"+ip, now)) >= failsPerIP || len(l.recent("user:"+strings.ToLower(user), now)) >= failsPerUser
}

func (l *Limiter) Fail(ip, user string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	// many different names or addresses: drop the ones with nothing recent
	if len(l.fails) > 5000 {
		for k := range l.fails {
			if len(l.recent(k, now)) == 0 {
				delete(l.fails, k)
			}
		}
	}
	l.fails["ip:"+ip] = append(l.recent("ip:"+ip, now), now)
	k := "user:" + strings.ToLower(user)
	l.fails[k] = append(l.recent(k, now), now)
}
