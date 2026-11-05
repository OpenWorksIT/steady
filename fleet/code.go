// Which code OpenWorks' own services run: the fleet view itself and the community sign-in bridge.
// Both are built from a signed release in /opt/steady-ops (docs/FLEET.md, docs/COMMUNITY.md). The
// Docker builds stamp each with the release's VERSION and a fingerprint of its code
// (deploy/code-of.sh), and the fleet view's build also stamps the bridge's fingerprint for the
// same release, so it can tell when the bridge runs something else: built from another checkout,
// or not rebuilt after an update. The practice servers' versions come with their status.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Set by the Docker build (fleet/Dockerfile); "dev" and empty in a build without them.
var (
	buildVersion = "dev"
	buildCode    = ""
	bridgeCode   = "" // the sign-in bridge's code in the same release
)

// BridgeStatus is the sign-in bridge's last answer to GET /version.
type BridgeStatus struct {
	URL, Version, Code, Err string
	At                      time.Time
}

func (p *Poller) fetchBridge(ctx context.Context, url string) *BridgeStatus {
	st := &BridgeStatus{URL: url, At: time.Now()}
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(url, "/")+"/version", nil)
	if err != nil {
		st.Err = err.Error()
		return st
	}
	req.Header.Set("Accept", "application/json")
	res, err := p.client.Do(req)
	if err != nil {
		st.Err = "can't reach the sign-in bridge: " + shortErr(err)
		return st
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	if res.StatusCode == http.StatusNotFound {
		st.Err = "it runs an older build that doesn't say which code it runs"
		return st
	}
	if res.StatusCode != 200 {
		st.Err = fmt.Sprintf("the sign-in bridge answered %d", res.StatusCode)
		return st
	}
	var v struct{ Version, Code string }
	if json.Unmarshal(body, &v) != nil {
		st.Err = "the sign-in bridge's answer isn't one it would give"
		return st
	}
	st.Version, st.Code = clip(v.Version, 40), clip(v.Code, 40)
	return st
}

// OwnService is one of OpenWorks' own services on the overview and the checks page.
type OwnService struct {
	Name, Runs, Note string
	Level            string // good, warn or bad
	Fix              string // the command that sees to it, when there's something to do
}

// newestRelease: the newest signed release any practice server reports ("1.1.1"), or "".
func newestRelease(sts []*Status) string {
	best := ""
	for _, st := range sts {
		if st == nil || st.Data == nil {
			continue
		}
		rel := strings.TrimPrefix(str(get(st.Data, "version", "latest", "release")), "v")
		if rel != "" && (best == "" || versionLess(best, rel)) {
			best = rel
		}
	}
	return best
}

// versionLess compares "1.1.0" and "1.1.1" number by number; anything else sorts first.
func versionLess(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x < y
		}
	}
	return false
}

const opsUpdate = "the fleet view's update (docs/FLEET.md, \"Updating the fleet view\")"

// ownServices: the fleet view and, once community.json names it, the sign-in bridge.
func ownServices(sts []*Status, cst *CommunityStatus) []OwnService {
	newest := newestRelease(sts)
	fleet := OwnService{Name: "Fleet view", Runs: buildVersion}
	if buildCode != "" {
		fleet.Runs += " (code " + buildCode + ")"
	}
	switch {
	case buildVersion == "dev":
		fleet.Level, fleet.Note = "warn", "a build without a release number: build it from a signed release in /opt/steady-ops"
		fleet.Fix = opsUpdate
	case newest != "" && versionLess(buildVersion, newest):
		fleet.Level, fleet.Note = "warn", newest+" is out: update the fleet view"
		fleet.Fix = opsUpdate
	default:
		fleet.Level, fleet.Note = "good", "the newest signed release"
	}
	out := []OwnService{fleet}
	if cst == nil {
		return out
	}
	bridge := OwnService{Name: "Sign-in bridge"}
	rebuild := "cd /opt/steady-ops && sudo docker compose -f community/signin/compose.yml up -d --build"
	b := cst.Bridge
	switch {
	case b == nil:
		bridge.Level, bridge.Runs = "warn", "not checked"
		bridge.Note = `add "signin": "https://signin.steadyapp.co.za" to community.json, so the fleet view checks which code it runs`
	case b.Err != "":
		bridge.Level, bridge.Runs, bridge.Note, bridge.Fix = "bad", "?", b.Err, rebuild
	case bridgeCode == "":
		bridge.Level, bridge.Runs = "warn", b.Version+" (code "+b.Code+")"
		bridge.Note = "can't compare: the fleet view itself isn't a release build"
	case b.Code != bridgeCode:
		bridge.Level, bridge.Runs = "bad", b.Version+" (code "+b.Code+")"
		bridge.Note = "not the code of release " + buildVersion + " (" + bridgeCode + "): it was built from somewhere else, or not rebuilt after the update"
		bridge.Fix = rebuild
	default:
		bridge.Level, bridge.Runs, bridge.Note = "good", b.Version+" (code "+b.Code+")", "the same code as the fleet view's release"
	}
	return append(out, bridge)
}
