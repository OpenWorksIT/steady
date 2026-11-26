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
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	pbkdfIter = 600000
	// The fleet view is a screen that stays on, so a sign-in lasts: up to sessionMax from signing
	// in (then the password and a code again), and through a computer asleep overnight, a tab
	// the browser put to sleep, a browser restart or a fleet view restart, as long as the browser
	// asked within sessionIdle. An open tab asks once a minute (the /alive frame). Signing out,
	// a changed password or authenticator, or being taken out of users.json ends it at once.
	sessionMax       = 7 * 24 * time.Hour
	sessionIdle      = 24 * time.Hour
	sessionSaveEvery = 5 * time.Minute // how often an open tab's "last seen" is written down
	aliveEvery       = 60              // seconds between the /alive frame's visits
	failWindow       = 15 * time.Minute
	failsPerIP       = 8
	failsPerUser     = 10
)

// User is one person allowed into the fleet view.
type User struct {
	Name     string `json:"name"`
	Salt     string `json:"salt"`
	Hash     string `json:"hash"`
	Iter     int    `json:"iter"`
	TOTP     string `json:"totp"`     // base32 secret
	LastStep int64  `json:"lastStep"` // the last TOTP step used, so a code works only once
	// Role: "admin" watches, reads and reports; "dev" also sees the commands that change a
	// server (run over SSH, never from the website). Empty: someone added before roles, a dev.
	Role string `json:"role,omitempty"`
}

// IsDev: a dev's login (and anyone added before roles existed).
func (u User) IsDev() bool { return u.Role == "dev" || u.Role == "" }

// Cred is a short fingerprint of the user's password and authenticator secret (not the code
// last used): a session remembers it, so changing either signs that person out everywhere.
func (u User) Cred() string {
	sum := sha256.Sum256([]byte("fleet-cred\x00" + u.Salt + "\x00" + u.Hash + "\x00" + u.TOTP))
	return hex.EncodeToString(sum[:8])
}

func (u User) RoleName() string {
	if u.IsDev() {
		return "dev"
	}
	return "admin"
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

// Session is one signed-in browser. Flash is a message for the next page (kept here, not in
// the address, so nobody can put words on the page with a link).
type Session struct {
	User    string    `json:"user"`
	Cred    string    `json:"cred"` // the user's Cred() when they signed in
	Dev     bool      `json:"-"`    // refreshed from users.json on every request
	CSRF    string    `json:"csrf"`
	Started time.Time `json:"started"`
	Seen    time.Time `json:"seen"`
	Flash   string    `json:"-"`
}

func (ss *Session) live(now time.Time) bool {
	return now.Sub(ss.Seen) <= sessionIdle && now.Sub(ss.Started) <= sessionMax
}

// Sessions are kept in memory and in sessions.json in the data folder, so a restart of the
// fleet view signs nobody out. The file holds a hash of each cookie, never the cookie itself:
// a copy of it (a backup, say) signs nobody in.
type Sessions struct {
	mu    sync.Mutex
	m     map[string]*Session // by sessionKey(the cookie's value)
	path  string              // "" in memory only
	saved time.Time
}

func sessionKey(id string) string {
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:])
}

// NewSessions keeps sessions in memory only.
func NewSessions() *Sessions { return &Sessions{m: map[string]*Session{}} }

// LoadSessions keeps sessions in the file at path too, starting with the live ones in it.
func LoadSessions(path string, now time.Time) *Sessions {
	s := &Sessions{m: map[string]*Session{}, path: path}
	var saved map[string]*Session
	if err := readJSON(path, &saved); err != nil {
		fmt.Fprintln(os.Stderr, "fleet: sessions.json can't be read, so everyone signs in again:", err)
	}
	for k, ss := range saved {
		if ss != nil && len(k) == 64 && ss.User != "" && ss.live(now) {
			s.m[k] = ss
		}
	}
	return s
}

// save writes the live sessions down (s.mu held). A failure only means a restart signs
// people out.
func (s *Sessions) save(now time.Time) {
	for k, ss := range s.m {
		if !ss.live(now) {
			delete(s.m, k)
		}
	}
	s.saved = now
	if s.path == "" {
		return
	}
	if err := writeJSON(s.path, s.m); err != nil {
		fmt.Fprintln(os.Stderr, "fleet: sessions.json can't be written:", err)
	}
}

func (s *Sessions) New(user, cred string, now time.Time) (string, *Session) {
	id := base64.RawURLEncoding.EncodeToString(randomBytes(32))
	ss := &Session{User: user, Cred: cred, CSRF: base64.RawURLEncoding.EncodeToString(randomBytes(24)), Started: now, Seen: now}
	s.mu.Lock()
	s.m[sessionKey(id)] = ss
	s.save(now)
	s.mu.Unlock()
	return id, ss
}

// Get returns a live session, and keeps it alive: any request from an open tab counts.
func (s *Sessions) Get(id string, now time.Time) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := sessionKey(id)
	ss := s.m[k]
	if ss == nil {
		return nil
	}
	if !ss.live(now) {
		delete(s.m, k)
		s.save(now)
		return nil
	}
	ss.Seen = now
	if now.Sub(s.saved) >= sessionSaveEvery || now.Before(s.saved) {
		s.save(now)
	}
	return ss
}

func (s *Sessions) SetFlash(ss *Session, msg string) {
	s.mu.Lock()
	ss.Flash = msg
	s.mu.Unlock()
}

func (s *Sessions) TakeFlash(ss *Session) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := ss.Flash
	ss.Flash = ""
	return m
}

func (s *Sessions) End(id string, now time.Time) {
	s.mu.Lock()
	k := sessionKey(id)
	if _, ok := s.m[k]; ok {
		delete(s.m, k)
		s.save(now)
	}
	s.mu.Unlock()
}

// Limiter counts sign-in attempts per address and wrong codes per name. An attempt takes its
// slot before the (slow) password check, so a burst of requests can't all slip through.
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
	if len(keep) == 0 {
		delete(l.fails, key)
	} else {
		l.fails[key] = keep
	}
	return keep
}

func (l *Limiter) sweep(now time.Time) {
	if len(l.fails) > 5000 {
		for k := range l.fails {
			l.recent(k, now)
		}
	}
}

// Take records an attempt for key, unless it already has limit recent ones (false).
func (l *Limiter) Take(key string, limit int, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sweep(now)
	r := l.recent(key, now)
	if len(r) >= limit {
		return false
	}
	l.fails[key] = append(r, now)
	return true
}

// Give takes back the attempt recorded at t (a sign-in that worked).
func (l *Limiter) Give(key string, t time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	r := l.fails[key]
	for i := range r {
		if r[i].Equal(t) {
			l.fails[key] = append(r[:i], r[i+1:]...)
			return
		}
	}
}

// Blocked is true while key has limit or more recent attempts.
func (l *Limiter) Blocked(key string, limit int, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent(key, now)) >= limit
}

// addrKey groups IPv6 addresses by their /64, the block one customer usually gets.
func addrKey(ip string) string {
	a := net.ParseIP(ip)
	if a == nil {
		if len(ip) > 64 {
			ip = ip[:64]
		}
		return "ip:" + ip
	}
	if a.To4() == nil {
		return "ip:" + a.Mask(net.CIDRMask(64, 128)).String() + "/64"
	}
	return "ip:" + a.String()
}
