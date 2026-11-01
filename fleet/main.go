// Steady fleet view: OpenWorks IT's overview of every practice's Steady server (version,
// health, disk, backups, counts), with Check / Update / Restart. Standard library only.
//
//	fleet serve                 run the site (FLEET_ADDR, default :8080; data in FLEET_DATA, default /data)
//	fleet adduser <name>        add someone: asks for a password, prints the authenticator setup
//	fleet passwd <name>         a new password for someone
//	fleet resettotp <name>      a new authenticator secret for someone (a lost phone)
//	fleet deluser <name>        remove someone
//	fleet healthz               exits 0 when the site answers (the container's health check)
//
// See docs/FLEET.md.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	store := NewStore(env("FLEET_DATA", "/data"))
	if len(os.Args) < 2 {
		usage()
	}
	cmd := os.Args[1]
	name := ""
	if len(os.Args) > 2 {
		name = os.Args[2]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(store)
	case "adduser":
		err = addUser(store, name)
	case "passwd":
		err = changeUser(store, name, true, false)
	case "resettotp":
		err = changeUser(store, name, false, true)
	case "deluser":
		err = delUser(store, name)
	case "healthz":
		// for the container's health check (the image has no curl)
		res, herr := http.Get("http://127.0.0.1" + env("FLEET_ADDR", ":8080") + "/healthz")
		if herr != nil || res.StatusCode != 200 {
			os.Exit(1)
		}
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "fleet:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: fleet serve | adduser <name> | passwd <name> | resettotp <name> | deluser <name>")
	os.Exit(2)
}

func serve(store *Store) error {
	if _, err := store.Servers(); err != nil {
		return err
	}
	if u, err := store.Users(); err != nil {
		return err
	} else if len(u) == 0 {
		fmt.Fprintln(os.Stderr, "fleet: nobody can sign in yet: run `fleet adduser <name>`")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	poller := NewPoller(store)
	go poller.Run(ctx, time.Minute)
	// FLEET_TRUSTED_PROXY: the reverse proxy's host name (e.g. caddy) or address. Only its
	// X-Forwarded-For is believed; unset, every visitor is taken at the connection's address.
	app := NewApp(store, poller, strings.TrimSpace(os.Getenv("FLEET_TRUSTED_PROXY")))
	srv := &http.Server{Addr: env("FLEET_ADDR", ":8080"), Handler: app.Routes(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, MaxHeaderBytes: 1 << 16}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(sctx)
	}()
	fmt.Println("fleet: listening on", srv.Addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

func readPassword() (string, error) {
	fmt.Fprint(os.Stderr, "Password (at least 14 characters; it shows as you type, so check nobody's watching): ")
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return "", err
	}
	pw := strings.TrimRight(line, "\r\n")
	if len(pw) < 14 {
		return "", fmt.Errorf("choose a password of at least 14 characters")
	}
	return pw, nil
}

// validName: plain lowercase ASCII (a-z, 0-9, . _ -), up to 40 characters, so names can't
// look alike in another script or fill the logs.
func validName(name string) error {
	if name == "" || len(name) > 40 {
		return fmt.Errorf("give a short name: a-z, 0-9, dot, dash or underscore, e.g. jane")
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return fmt.Errorf("give a short name: a-z, 0-9, dot, dash or underscore, e.g. jane")
		}
	}
	return nil
}

func showTOTP(u User) {
	fmt.Println("\nIn your authenticator app, add an account by key (or turn this link into a QR code):")
	fmt.Println("  key:  ", u.TOTP)
	fmt.Println("  link: ", OTPAuthURI(u))
}

func addUser(store *Store, name string) error {
	name = strings.ToLower(name)
	if err := validName(name); err != nil {
		return err
	}
	// the password is asked first, outside the lock on users.json
	pw, err := readPassword()
	if err != nil {
		return err
	}
	u := NewUser(name, pw)
	err = store.UpdateUsers(func(all []User) ([]User, error) {
		for _, x := range all {
			if sameName(x.Name, name) {
				return nil, fmt.Errorf("%s already exists", name)
			}
		}
		return append(all, u), nil
	})
	if err != nil {
		return err
	}
	showTOTP(u)
	fmt.Println("\nAdded", name+".")
	return nil
}

func changeUser(store *Store, name string, password, totp bool) error {
	fresh := NewUser(name, "unused")
	if password {
		pw, err := readPassword()
		if err != nil {
			return err
		}
		fresh = NewUser(name, pw)
	}
	var changed User
	err := store.UpdateUsers(func(all []User) ([]User, error) {
		for i := range all {
			if sameName(all[i].Name, name) {
				if password {
					all[i].Salt, all[i].Hash, all[i].Iter = fresh.Salt, fresh.Hash, fresh.Iter
				}
				if totp {
					all[i].TOTP, all[i].LastStep = fresh.TOTP, 0
				}
				changed = all[i]
				return all, nil
			}
		}
		return nil, fmt.Errorf("no user called %s", name)
	})
	if err != nil {
		return err
	}
	if totp {
		showTOTP(changed)
	}
	fmt.Println("Changed", changed.Name+". Anyone signed in keeps their session until it ends (restart the fleet view to end them now).")
	return nil
}

func delUser(store *Store, name string) error {
	return store.UpdateUsers(func(all []User) ([]User, error) {
		var keep []User
		for _, u := range all {
			if !sameName(u.Name, name) {
				keep = append(keep, u)
			}
		}
		if len(keep) == len(all) {
			return nil, fmt.Errorf("no user called %s", name)
		}
		return keep, nil
	})
}
