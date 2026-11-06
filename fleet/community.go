// The Steady community forum's activity counts (docs/COMMUNITY.md): how many members, topics
// and posts, site-wide. Only numbers are kept; never titles, names or text. Read from
// Discourse's /about.json with the openworks-stats key, every 10 minutes (Discourse itself
// refreshes them about every 30).
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Community is community.json: {"url": "https://community.steadyapp.co.za", "statsKey": "...",
// "signin": "https://signin.steadyapp.co.za"}. signin (optional): the sign-in bridge, whose code
// the fleet view checks against its own release (code.go).
type Community struct {
	URL      string `json:"url"`
	StatsKey string `json:"statsKey"`
	Signin   string `json:"signin,omitempty"`
}

// CommunityStatus is the forum's last answer: numbers only.
type CommunityStatus struct {
	URL    string
	At     time.Time
	Err    string
	Counts map[string]float64
	Bridge *BridgeStatus // nil: community.json names no sign-in bridge
}

// the /about.json "stats" fields kept, and nothing else
var communityFields = []string{
	"users_count", "active_users_last_day", "active_users_7_days", "active_users_30_days",
	"participating_users_7_days", "topics_count", "topics_7_days", "posts_count", "posts_7_days",
	"likes_7_days",
}

// Community reads community.json; no file means no forum yet (nil, nil).
func (s *Store) Community() (*Community, error) {
	var c Community
	if err := readJSON(s.path("community.json"), &c); err != nil {
		return nil, fmt.Errorf("community.json: %v", err)
	}
	if c == (Community{}) {
		return nil, nil // no file (or an empty one): no forum yet
	}
	if !strings.HasPrefix(c.URL, "https://") {
		return nil, fmt.Errorf("community.json: the url must start with https://")
	}
	if len(c.StatsKey) < 32 {
		return nil, fmt.Errorf("community.json: statsKey looks too short")
	}
	if c.Signin != "" && !strings.HasPrefix(c.Signin, "https://") {
		return nil, fmt.Errorf("community.json: signin must start with https://")
	}
	return &c, nil
}

func (p *Poller) fetchCommunity(ctx context.Context) *CommunityStatus {
	c, err := p.store.Community()
	if c == nil && err == nil {
		return nil
	}
	st := &CommunityStatus{At: time.Now()}
	if err != nil {
		st.Err = err.Error()
		return st
	}
	st.URL = c.URL
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(c.URL, "/")+"/about.json", nil)
	if err != nil {
		st.Err = err.Error()
		return st
	}
	req.Header.Set("Api-Key", c.StatsKey)
	req.Header.Set("Accept", "application/json")
	res, err := p.client.Do(req)
	if err != nil {
		st.Err = "can't reach the forum: " + shortErr(err)
		return st
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	switch {
	case res.StatusCode >= 300 && res.StatusCode < 400:
		st.Err = "the forum sent us to its sign-in page: the stats key wasn't accepted (wrong or revoked)"
		return st
	case res.StatusCode == 401 || res.StatusCode == 403:
		st.Err = "the forum refused the stats key (wrong, revoked, or openworks-stats suspended)"
		return st
	case res.StatusCode != 200:
		st.Err = fmt.Sprintf("the forum answered %d", res.StatusCode)
		return st
	}
	var about struct {
		About struct {
			Stats map[string]any `json:"stats"`
		} `json:"about"`
	}
	if json.Unmarshal(body, &about) != nil || about.About.Stats == nil {
		st.Err = "no counts in the forum's answer (is it a Discourse forum?)"
		return st
	}
	st.Counts = map[string]float64{}
	for _, k := range communityFields {
		if v, ok := about.About.Stats[k].(float64); ok {
			st.Counts[k] = v
		}
	}
	return st
}

func (p *Poller) PollCommunity(ctx context.Context) {
	st := p.fetchCommunity(ctx)
	if c, _ := p.store.Community(); st != nil && c != nil && c.Signin != "" {
		st.Bridge = p.fetchBridge(ctx, c.Signin)
	}
	p.mu.Lock()
	p.community = st
	p.mu.Unlock()
}

func (p *Poller) CommunitySnapshot() *CommunityStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.community
}

// CommunityView is what the overview shows.
type CommunityView struct {
	Domain, Checked, Err string
	Members, Active7d    string
	Topics, Posts        string
	Participating7d      string
}

func makeCommunity(st *CommunityStatus, now time.Time) *CommunityView {
	if st == nil {
		return nil
	}
	v := &CommunityView{Domain: strings.TrimPrefix(st.URL, "https://"), Checked: ago(st.At, now), Err: st.Err}
	if st.Err != "" {
		return v
	}
	n := func(k string) string {
		if x, ok := st.Counts[k]; ok {
			return fmt.Sprintf("%.0f", x)
		}
		return "–"
	}
	withWeek := func(total, week string) string {
		if _, ok := st.Counts[week]; !ok {
			return n(total)
		}
		return n(total) + " (" + n(week) + " this week)"
	}
	v.Members = n("users_count")
	v.Active7d = n("active_users_7_days")
	v.Participating7d = n("participating_users_7_days")
	v.Topics = withWeek("topics_count", "topics_7_days")
	v.Posts = withWeek("posts_count", "posts_7_days")
	return v
}
