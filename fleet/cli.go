// The fleet view's commands for devs, run over SSH on vps1 (fleet/fleet.sh). The website only
// looks: everything that changes a practice's server happens here, behind SSH keys and sudo, and
// each command goes in the fleet view's log with who ran it (FLEET_ACTOR, from sudo).
//
//	fleet servers                       the servers, with the short name each command takes
//	fleet check <server>                look for a newer signed release (changes nothing)
//	fleet update <server> [--yes]       install the latest signed release
//	fleet restart <server> [--yes]      restart Steady on that server
//	fleet reset <server> <email> [--two-step] [--yes]
//	                                    reset a staff member's password: the temporary password
//	                                    shows here (tell them by phone), and the server emails them
//	                                    a code; both are needed, so the fleet key alone can't take
//	                                    an account over. --two-step also clears their authenticator.
//
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strings"
	"time"
)

// ShortName: the first part of a server's address ("vr" for https://vr.steadyapp.co.za), which
// the commands take; the practice's full name or its address work too.
func (sv Server) ShortName() string {
	host := strings.TrimPrefix(strings.TrimPrefix(sv.URL, "https://"), "http://")
	host = strings.ToLower(strings.SplitN(strings.SplitN(host, "/", 2)[0], ":", 2)[0])
	if net.ParseIP(host) != nil {
		return host // an address without a name (tests, a server not yet in DNS)
	}
	return strings.SplitN(host, ".", 2)[0]
}

// findServer: by short name, full name or address (any case); exactly one must match.
func findServer(store *Store, which string) (Server, error) {
	servers, err := store.Servers()
	if err != nil {
		return Server{}, err
	}
	w := strings.ToLower(strings.TrimSpace(which))
	var found []Server
	for _, sv := range servers {
		host := strings.ToLower(strings.TrimPrefix(strings.TrimPrefix(sv.URL, "https://"), "http://"))
		if w != "" && (w == sv.ShortName() || w == strings.ToLower(sv.Name) || w == strings.TrimRight(host, "/") || w == strings.ToLower(strings.TrimRight(sv.URL, "/"))) {
			found = append(found, sv)
		}
	}
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		return Server{}, fmt.Errorf("no server called %q: `fleet servers` lists them", which)
	}
	return Server{}, fmt.Errorf("%q matches %d servers: use its address", which, len(found))
}

// actor: who runs the command, from sudo (fleet.sh passes SUDO_USER); "ssh" when it doesn't say.
func actor() string {
	a := strings.TrimSpace(os.Getenv("FLEET_ACTOR"))
	if validName(strings.ToLower(a)) != nil {
		return "ssh"
	}
	return strings.ToLower(a) + " (ssh)"
}

func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

// valueFlags take the next word as their value ("--group practice-vr").
var valueFlags = map[string]bool{"--group": true}

func positional(args []string) []string {
	var out []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if valueFlags[a] {
			i++
			continue
		}
		if !strings.HasPrefix(a, "--") {
			out = append(out, a)
		}
	}
	return out
}

// confirm asks the dev to type the server's short name before a change, unless --yes.
func confirm(in io.Reader, out io.Writer, sv Server, what string, args []string) error {
	if hasFlag(args, "--yes") {
		return nil
	}
	fmt.Fprintf(out, "To %s on %s (%s), type %s: ", what, sv.Name, sv.URL, sv.ShortName())
	line, _ := bufio.NewReader(in).ReadString('\n')
	if strings.TrimSpace(strings.ToLower(line)) != sv.ShortName() {
		return fmt.Errorf("not confirmed: nothing was changed")
	}
	return nil
}

var serverActions = map[string]string{
	"check":   "check for updates",
	"update":  "install the latest signed release",
	"restart": "restart Steady",
}

func listServers(store *Store, out io.Writer) error {
	servers, err := store.Servers()
	if err != nil {
		return err
	}
	if len(servers) == 0 {
		fmt.Fprintln(out, "No servers in servers.json yet (docs/FLEET.md).")
	}
	for _, sv := range servers {
		fmt.Fprintf(out, "  %-12s %-32s %s\n", sv.ShortName(), sv.Name, sv.URL)
	}
	return nil
}

// serverAction: check, update or restart one server, through its fleet key.
func serverAction(store *Store, act string, args []string, in io.Reader, out io.Writer) error {
	pos := positional(args)
	if len(pos) != 1 {
		return fmt.Errorf("usage: fleet %s <server> [--yes]", act)
	}
	sv, err := findServer(store, pos[0])
	if err != nil {
		return err
	}
	what := serverActions[act]
	if act != "check" {
		if err := confirm(in, out, sv, what, args); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err = NewPoller(store).Request(ctx, sv, act)
	detail := "ok"
	if err != nil {
		detail = err.Error()
	}
	store.Audit(actor(), "ssh", act, sv.Name+": "+detail)
	if err != nil {
		return fmt.Errorf("couldn't ask %s: %v", sv.Name, err)
	}
	fmt.Fprintf(out, "Asked %s to %s. It does so within a minute; the fleet view shows the result.\n", sv.Name, what)
	return nil
}

// resetPassword: a staff member's password, through the fleet key; the person finishes it with
// the temporary password shown here and the code the server emails them.
func resetPassword(store *Store, args []string, in io.Reader, out io.Writer) error {
	pos := positional(args)
	if len(pos) != 2 || !strings.Contains(pos[1], "@") {
		return fmt.Errorf("usage: fleet reset <server> <email> [--two-step] [--yes]")
	}
	sv, err := findServer(store, pos[0])
	if err != nil {
		return err
	}
	two := hasFlag(args, "--two-step")
	what := "reset the password of " + pos[1]
	if two {
		what += " and clear their two-step sign-in"
	}
	if err := confirm(in, out, sv, what, args); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	r, err := NewPoller(store).Reset(ctx, sv, pos[1], two)
	detail := "ok"
	if err != nil {
		detail = err.Error()
	}
	// the log has who and which account, never the temporary password
	store.Audit(actor(), "ssh", "reset", sv.Name+": "+clip(strings.ToLower(pos[1]), 120)+map[bool]string{true: " (two-step)", false: ""}[two]+": "+detail)
	if err != nil {
		return fmt.Errorf("couldn't reset it on %s: %v", sv.Name, err)
	}
	fmt.Fprintf(out, "\nReset %s (%s) on %s.\n", r.Account.Name, r.Account.Role, sv.Name)
	fmt.Fprintf(out, "  Temporary password:  %s\n", r.TemporaryPassword)
	fmt.Fprintln(out, "  Tell them this by phone, never by email or message.")
	fmt.Fprintf(out, "  They also need the code Steady just emailed to %s (it works for 24 hours).\n", r.EmailedTo)
	if r.TwoStepCleared {
		fmt.Fprintln(out, "  Two-step sign-in was cleared: they set it up again after signing in.")
	}
	fmt.Fprintln(out, "  Their devices are unlinked, and their master psychologist has been told.")
	return nil
}

// community: run a practice's part of the community from here (bridge.go).
//
//	fleet community                                   every practice in it, with who's waiting
//	fleet community <server> on [--openworks] [--approve-all] [--group practice-vr]
//	fleet community <server> off
//	fleet community <server> people                   who the practice put in; approved or waiting
//	fleet community <server> approve <email>...
//	fleet community <server> remove <email>...
func communityCmd(store *Store, args []string, in io.Reader, out io.Writer) error {
	pos := positional(args)
	if len(pos) == 0 {
		return listCommunity(store, out)
	}
	if len(pos) < 2 {
		return fmt.Errorf("usage: fleet community [<server> on|off|people|approve <email>|remove <email>]")
	}
	sv, err := findServer(store, pos[0])
	if err != nil {
		return err
	}
	id := sv.ShortName()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	p := NewPoller(store)
	switch pos[1] {
	case "on":
		cfg, err := store.Community()
		if err != nil {
			return err
		}
		if cfg == nil || cfg.Signin == "" {
			return fmt.Errorf(`community.json needs "url" and "signin" first (docs/FLEET.md, step 6)`)
		}
		openworks := hasFlag(args, "--openworks")
		what := "switch the community on"
		if openworks {
			what += " as OpenWorks' own server (OpenWorks support comes in here)"
		}
		if err := confirm(in, out, sv, what, args); err != nil {
			return err
		}
		key := newCommunityKey()
		existing, _ := store.CommunityPractices()
		if e := existing.Practices[id]; e != nil && e.Key != "" {
			key = e.Key // switched on again: the same key, so the server and bridge keep agreeing
		}
		_, err = p.post(ctx, sv, "/api/steady/fleet/community", map[string]any{"on": true, "forum": cfg.URL, "signin": cfg.Signin, "key": key, "openworks": openworks})
		if err != nil {
			store.Audit(actor(), "ssh", "community on", sv.Name+": "+err.Error())
			return fmt.Errorf("couldn't switch it on at %s: %v", sv.Name, err)
		}
		var approved []string
		serverOn := true
		if st := p.Status(ctx, sv); st.Err == "" {
			on, _, members := communityOf(st.Data)
			serverOn = on
			if hasFlag(args, "--approve-all") {
				for _, m := range members {
					approved = append(approved, m.Email)
				}
			}
		}
		group := flagValue(args, "--group")
		err = store.withCommunity(func(cp *CommunityPractices) (bool, error) {
			pr := cp.Practices[id]
			if pr == nil {
				pr = &CommunityPractice{ID: id}
				cp.Practices[id] = pr
			}
			pr.Name, pr.URL, pr.Key, pr.OpenWorks = sv.Name, strings.TrimRight(sv.URL, "/"), key, openworks
			if group != "" {
				pr.Groups = []string{group}
			}
			pr.Approved = union(pr.Approved, approved)
			return true, nil
		})
		store.Audit(actor(), "ssh", "community on", sv.Name+fmt.Sprintf(": %d approved", len(approved)))
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "The community is on for %s. Its master psychologist adds staff in Settings > Practice > Community;\nthey show here to approve: fleet community %s people\n", sv.Name, id)
		if len(approved) > 0 {
			fmt.Fprintf(out, "Approved now: %s\n", strings.Join(approved, ", "))
		}
		if !serverOn {
			fmt.Fprintf(out, "But %s still says the community is off: Steady before 1.2.1 can't read the fleet view's setting. Update it, then run this again.\n", sv.Name)
		}
		cp, _ := store.CommunityPractices()
		if pr := cp.Practices[id]; pr == nil || len(pr.Approved) == 0 {
			fmt.Fprintf(out, "Nobody is approved yet, so the sign-in bridge doesn't list %s until someone is.\n", sv.Name)
		}
		return nil
	case "off":
		if err := confirm(in, out, sv, "switch the community off (nobody there can open it until it's on again)", args); err != nil {
			return err
		}
		if _, err := p.post(ctx, sv, "/api/steady/fleet/community", map[string]any{"on": false}); err != nil {
			fmt.Fprintf(out, "Couldn't tell %s (%v): it's off at the bridge anyway.\n", sv.Name, err)
		}
		err := store.withCommunity(func(cp *CommunityPractices) (bool, error) {
			if cp.Practices[id] == nil {
				return false, nil
			}
			delete(cp.Practices, id)
			return true, nil
		})
		store.Audit(actor(), "ssh", "community off", sv.Name)
		if err == nil {
			fmt.Fprintf(out, "The community is off for %s. Forum accounts stay; log them out in the forum (Admin > Users) if they shouldn't come back.\n", sv.Name)
		}
		return err
	case "people":
		st := p.Status(ctx, sv)
		if st.Err != "" {
			return fmt.Errorf("couldn't reach %s: %s", sv.Name, st.Err)
		}
		on, _, members := communityOf(st.Data)
		cp, _ := store.CommunityPractices()
		pr := cp.Practices[id]
		if !on {
			fmt.Fprintf(out, "The community is off at %s.\n", sv.Name)
		}
		waiting := map[string]bool{}
		for _, m := range pending(pr, members) {
			waiting[m.Email] = true
		}
		for _, m := range members {
			state := "approved"
			if waiting[m.Email] {
				state = "WAITING"
			}
			fmt.Fprintf(out, "  %-9s %-34s %-28s %s\n", state, m.Email, m.Name, m.Role)
		}
		if len(members) == 0 {
			fmt.Fprintln(out, "  Nobody yet: the master psychologist adds staff in Settings > Practice > Community.")
		}
		if len(waiting) > 0 {
			fmt.Fprintf(out, "\nApprove with: fleet community %s approve <email>\n", id)
		}
		return nil
	case "approve", "remove":
		emails := pos[2:]
		if len(emails) == 0 {
			return fmt.Errorf("usage: fleet community %s %s <email>...", id, pos[1])
		}
		var members []Member
		if pos[1] == "approve" {
			st := p.Status(ctx, sv)
			if st.Err != "" {
				return fmt.Errorf("couldn't reach %s to check its list: %s", sv.Name, st.Err)
			}
			_, _, members = communityOf(st.Data)
		}
		listed := map[string]bool{}
		for _, m := range members {
			listed[m.Email] = true
		}
		var done []string
		err := store.withCommunity(func(cp *CommunityPractices) (bool, error) {
			pr := cp.Practices[id]
			if pr == nil {
				return false, fmt.Errorf("the community isn't on for %s: fleet community %s on", sv.Name, id)
			}
			for _, e := range emails {
				e = strings.ToLower(strings.TrimSpace(e))
				if pos[1] == "approve" {
					if !listed[e] {
						return false, fmt.Errorf("%s isn't on %s's list: its master psychologist adds them first (Settings > Practice > Community)", e, sv.Name)
					}
					pr.Approved = union(pr.Approved, []string{e})
				} else {
					pr.Approved = without(pr.Approved, e)
				}
				done = append(done, e)
			}
			return true, nil
		})
		if err != nil {
			return err
		}
		store.Audit(actor(), "ssh", "community "+pos[1], sv.Name+": "+clip(strings.Join(done, ", "), 250))
		fmt.Fprintf(out, "%s at %s: %s. The bridge has it within seconds.\n", map[string]string{"approve": "Approved", "remove": "Removed"}[pos[1]], sv.Name, strings.Join(done, ", "))
		return nil
	}
	return fmt.Errorf("usage: fleet community [<server> on|off|people|approve <email>|remove <email>]")
}

func listCommunity(store *Store, out io.Writer) error {
	cp, err := store.CommunityPractices()
	if err != nil {
		return err
	}
	if len(cp.Practices) == 0 {
		fmt.Fprintln(out, "No practice is run from here yet: fleet community <server> on")
		return nil
	}
	ids := make([]string, 0, len(cp.Practices))
	for id := range cp.Practices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		pr := cp.Practices[id]
		mark := ""
		if pr.OpenWorks {
			mark = "  (OpenWorks' own server)"
		}
		fmt.Fprintf(out, "  %-12s %-32s %d approved%s\n", id, pr.Name, len(pr.Approved), mark)
	}
	return nil
}

func flagValue(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
		if strings.HasPrefix(a, name+"=") {
			return strings.TrimPrefix(a, name+"=")
		}
	}
	return ""
}

func union(a, b []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, x := range append(append([]string{}, a...), b...) {
		x = strings.ToLower(strings.TrimSpace(x))
		if x != "" && !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}

func without(a []string, x string) []string {
	var out []string
	for _, y := range a {
		if y != x {
			out = append(out, y)
		}
	}
	return out
}
