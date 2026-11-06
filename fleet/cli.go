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

func positional(args []string) []string {
	var out []string
	for _, a := range args {
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
