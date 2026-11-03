// The bridge's settings: /data/config.json (SIGNIN_CONFIG), read again whenever it changes.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Practice is one practice's Steady server the forum accepts sign-ins from.
type Practice struct {
	// ID is part of every forum account made through this practice ("vr:<account id>"): never
	// change it once people have signed in, or they get new, empty forum accounts.
	ID   string `json:"id"`
	Name string `json:"name"`
	// URL is the practice's Steady web address, where people sign in.
	URL string `json:"url"`
	// Key is STEADY_COMMUNITY_KEY on that server: it signs the notes the bridge trusts.
	Key string `json:"key"`
	// Groups: more forum groups for its psychologists (a practice's private group), never for
	// its administrators.
	Groups []string `json:"groups,omitempty"`
	// Emails: the addresses its psychologists and practice administrators use, each an address
	// or "@domain" (the practice's own domain, never a public mail service's). Only these sign in
	// through this practice, and the forum takes them as they are: an account already on the
	// forum with the address carries on. No address or domain may be on two practices' lists, so
	// no practice can sign someone in as another practice's psychologist.
	Emails []string `json:"emails"`
	// Support: OpenWorks support accounts may come in through this practice's server (with an
	// address on the OpenWorks list). Only on a server OpenWorks alone runs: anyone who can make
	// a support account there, or holds its key, could come in as OpenWorks.
	Support bool `json:"support,omitempty"`
}

// Config is the whole settings file.
type Config struct {
	// URL is the bridge's own address (https://signin.steadyapp.co.za).
	URL string `json:"url"`
	// Forum is the forum's address (https://community.steadyapp.co.za).
	Forum string `json:"forum"`
	// ForumSecret is the forum's DiscourseConnect secret (DISCOURSE_DISCOURSE_CONNECT_SECRET).
	ForumSecret string `json:"forumSecret"`
	// OpenWorks: the addresses of OpenWorks IT's support accounts, one by one (no "@domain"). Only
	// a practice marked "support" may sign someone in as OpenWorks support, with one of these.
	OpenWorks []string   `json:"openworks"`
	Practices []Practice `json:"practices"`
}

const minKey = 32

var (
	reOrigin = regexp.MustCompile(`^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$`)
	reID     = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,15}$`)
	reGroup  = regexp.MustCompile(`^[a-z0-9_][a-z0-9_.-]{0,39}$`)
)

// origin: an https address with no path, lower case; "" if it isn't one.
func origin(s string) string {
	s = strings.ToLower(strings.TrimRight(strings.TrimSpace(s), "/"))
	if !reOrigin.MatchString(s) {
		return ""
	}
	return s
}

// validate checks the settings and tidies the addresses. The first problem found is returned.
func (c *Config) validate() error {
	if c.URL = origin(c.URL); c.URL == "" {
		return errors.New(`"url" must be the bridge's https address, like https://signin.steadyapp.co.za`)
	}
	if c.Forum = origin(c.Forum); c.Forum == "" {
		return errors.New(`"forum" must be the forum's https address, like https://community.steadyapp.co.za`)
	}
	if len(c.ForumSecret) < minKey {
		return fmt.Errorf(`"forumSecret" must be at least %d characters (signin newkey makes one)`, minKey)
	}
	if len(c.Practices) == 0 {
		return errors.New(`"practices" lists no practice, so nobody could sign in`)
	}
	seen := map[string]bool{}
	for i := range c.Practices {
		p := &c.Practices[i]
		label := fmt.Sprintf("practice %d", i+1)
		if !reID.MatchString(p.ID) {
			return fmt.Errorf(`%s: "id" must be 1 to 16 lower-case letters, digits or dashes, like "vr"`, label)
		}
		label = fmt.Sprintf("practice %q", p.ID)
		if seen[p.ID] {
			return fmt.Errorf("%s is listed twice", label)
		}
		seen[p.ID] = true
		if p.Name = strings.TrimSpace(p.Name); p.Name == "" || len(p.Name) > 80 {
			return fmt.Errorf(`%s: "name" is empty or too long`, label)
		}
		if p.URL = origin(p.URL); p.URL == "" {
			return fmt.Errorf(`%s: "url" must be its Steady https address, like https://vr.steadyapp.co.za`, label)
		}
		if len(p.Key) < minKey {
			return fmt.Errorf(`%s: "key" must be at least %d characters (STEADY_COMMUNITY_KEY on that server)`, label, minKey)
		}
		if p.Key == c.ForumSecret {
			return fmt.Errorf(`%s: "key" must not be the forum's secret`, label)
		}
		for j, g := range p.Groups {
			g = strings.ToLower(strings.TrimSpace(g))
			if !reGroup.MatchString(g) || g == "clinicians" || g == "practice-admins" || g == "openworks" {
				return fmt.Errorf(`%s: group %q isn't a group name the bridge may add (clinicians, practice-admins and openworks come from the role)`, label, p.Groups[j])
			}
			p.Groups[j] = g
		}
		if len(p.Emails) == 0 {
			return fmt.Errorf(`%s: "emails" must list the addresses (or "@domain") its psychologists and administrators use`, label)
		}
		if err := tidyList(p.Emails, label); err != nil {
			return err
		}
	}
	if err := tidyList(c.OpenWorks, `"openworks"`); err != nil {
		return err
	}
	for _, e := range c.OpenWorks {
		if strings.HasPrefix(e, "@") {
			return fmt.Errorf(`"openworks": list OpenWorks' support addresses one by one, not %q`, e)
		}
	}
	// nobody's address may be vouched for by two lists
	lists := map[string][]string{"OpenWorks support": c.OpenWorks}
	for _, p := range c.Practices {
		lists[fmt.Sprintf("practice %q", p.ID)] = p.Emails
	}
	for a, la := range lists {
		for b, lb := range lists {
			if a >= b {
				continue
			}
			for _, x := range la {
				for _, y := range lb {
					if overlaps(x, y) {
						return fmt.Errorf("%s and %s both list %s: an address may be vouched for by one list only", a, b, wider(x, y))
					}
				}
			}
		}
	}
	for i := range c.Practices {
		for j := range c.Practices {
			if i != j && c.Practices[i].Key == c.Practices[j].Key {
				return fmt.Errorf("practices %q and %q have the same key: each server needs its own", c.Practices[i].ID, c.Practices[j].ID)
			}
		}
	}
	return nil
}

func (c *Config) practice(id string) *Practice {
	for i := range c.Practices {
		if c.Practices[i].ID == id {
			return &c.Practices[i]
		}
	}
	return nil
}

// listed: the (lower-case) address is on the list, itself or by its domain.
func listed(list []string, email string) bool {
	at := strings.LastIndex(email, "@")
	for _, e := range list {
		if e == email || (strings.HasPrefix(e, "@") && at >= 0 && email[at:] == e) {
			return true
		}
	}
	return false
}

// public mail services: anyone can get an address there, so a practice may list single
// addresses at them, never the whole domain
var publicDomains = map[string]bool{
	"gmail.com": true, "googlemail.com": true, "outlook.com": true, "hotmail.com": true, "live.com": true,
	"msn.com": true, "yahoo.com": true, "ymail.com": true, "icloud.com": true, "me.com": true, "mac.com": true,
	"aol.com": true, "proton.me": true, "protonmail.com": true, "pm.me": true, "gmx.com": true, "gmx.net": true,
	"mail.com": true, "zoho.com": true, "yandex.com": true, "tutanota.com": true, "fastmail.com": true,
	"mweb.co.za": true, "telkomsa.net": true, "webmail.co.za": true, "vodamail.co.za": true, "iafrica.com": true,
	"absamail.co.za": true, "lantic.net": true, "afrihost.co.za": true, "cybersmart.co.za": true,
}

// tidyList lower-cases an address list and checks each entry.
func tidyList(list []string, label string) error {
	for j, e := range list {
		e = strings.ToLower(strings.TrimSpace(e))
		if strings.HasPrefix(e, "@") {
			d := e[1:]
			if !strings.Contains(d, ".") || strings.ContainsAny(d, "@ ") {
				return fmt.Errorf(`%s: %q isn't a domain like "@vrpsych.co.za"`, label, list[j])
			}
			if publicDomains[d] {
				return fmt.Errorf(`%s: %q is a public mail service: list the single addresses instead`, label, list[j])
			}
		} else if !validEmail(e) {
			return fmt.Errorf(`%s: %q isn't an email address`, label, list[j])
		}
		list[j] = e
	}
	return nil
}

// overlaps: two list entries can vouch for the same address.
func overlaps(x, y string) bool {
	switch {
	case x == y:
		return true
	case strings.HasPrefix(x, "@") && !strings.HasPrefix(y, "@"):
		return listed([]string{x}, y)
	case strings.HasPrefix(y, "@") && !strings.HasPrefix(x, "@"):
		return listed([]string{y}, x)
	}
	return false
}

func wider(x, y string) string {
	if strings.HasPrefix(y, "@") {
		return y
	}
	return x
}

// validEmail: one address, plain enough for the forum to take as it is.
func validEmail(e string) bool {
	if len(e) < 3 || len(e) > 254 || strings.Count(e, "@") != 1 || strings.HasPrefix(e, "@") || strings.HasSuffix(e, "@") {
		return false
	}
	for _, r := range e {
		if r <= ' ' || r == 0x7f || strings.ContainsRune(`"<>(),;:\[]`, r) {
			return false
		}
	}
	return strings.Contains(e[strings.Index(e, "@"):], ".")
}

// ConfigFile reads the settings file, again whenever it changes, so a practice is added or
// removed without a restart.
type ConfigFile struct {
	path    string
	mu      sync.Mutex
	stamp   string
	cfg     *Config
	err     error
	checked time.Time
}

func NewConfigFile(path string) *ConfigFile { return &ConfigFile{path: path} }

// Get returns the current settings, or why there are none.
func (f *ConfigFile) Get() (*Config, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if time.Since(f.checked) < 2*time.Second && (f.cfg != nil || f.err != nil) {
		return f.cfg, f.err
	}
	f.checked = time.Now()
	st, err := os.Stat(f.path)
	if err != nil {
		f.stamp, f.cfg, f.err = "", nil, fmt.Errorf("can't read %s: %w", f.path, err)
		return nil, f.err
	}
	stamp := fmt.Sprintf("%d/%d", st.ModTime().UnixNano(), st.Size())
	if stamp == f.stamp {
		return f.cfg, f.err
	}
	f.stamp = stamp
	f.cfg, f.err = loadConfig(f.path)
	return f.cfg, f.err
}

func loadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("can't read %s: %w", path, err)
	}
	var c Config
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("%s isn't valid: %w", path, err)
	}
	if err := c.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &c, nil
}
