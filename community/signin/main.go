// Steady community sign-in bridge: the community forum (Discourse, community.steadyapp.co.za)
// opens only inside Steady, in the Community tab of the app and the web app, signed in as whoever
// is signed in to Steady. The forum trusts this bridge (DiscourseConnect); the bridge trusts a
// short note signed by a practice's Steady server. Standard library only.
//
//	signin serve     run it (SIGNIN_ADDR, default :8080; settings in SIGNIN_CONFIG, default /data/config.json)
//	signin check     read the settings and say what's wrong, if anything
//	signin newkey    print a new random key: the forum's secret, or a practice's key
//	signin healthz   exits 0 when it answers and its settings are good (the container's health check)
//
// See docs/COMMUNITY.md, "Signing in through Steady".
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Which release and code this build is (the Docker build sets them from VERSION and
// deploy/code-of.sh); GET /version says so, for the fleet view.
var (
	buildVersion = "dev"
	buildCode    = ""
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	path := env("SIGNIN_CONFIG", "/data/config.json")
	switch os.Args[1] {
	case "serve":
		if err := serve(path); err != nil {
			fmt.Fprintln(os.Stderr, "signin:", err)
			os.Exit(1)
		}
	case "check":
		cfg, err := loadConfig(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, "signin:", err)
			os.Exit(1)
		}
		fmt.Printf("%s is fine: the forum %s, %d practice(s):\n", path, cfg.Forum, len(cfg.Practices))
		for _, p := range cfg.Practices {
			fmt.Printf("  %-8s %s  %s  (%s)\n", p.ID, p.Name, p.URL, strings.Join(p.Emails, ", "))
		}
		fmt.Printf("  OpenWorks support: %s\n", strings.Join(cfg.OpenWorks, ", "))
		support := []string{}
		for _, p := range cfg.Practices {
			if p.Support {
				support = append(support, p.ID)
			}
			// the web app's Community tab works only when the practice's Steady and the forum
			// share a site (the forum's cookies inside the frame); the phone app works anyway
			if parent := cfg.Forum[strings.Index(cfg.Forum, ".")+1:]; !strings.HasSuffix(p.URL, "."+parent) {
				fmt.Printf("  note: %s isn't under %s, so its web app has no Community tab (the phone app has)\n", p.URL, parent)
			}
		}
		fmt.Printf("  OpenWorks support comes in through: %s\n", strings.Join(support, ", "))
	case "newkey":
		b := make([]byte, 36)
		if _, err := rand.Read(b); err != nil {
			fmt.Fprintln(os.Stderr, "signin:", err)
			os.Exit(1)
		}
		fmt.Println(base64.RawURLEncoding.EncodeToString(b))
	case "healthz":
		// for the container's health check (the image has no curl)
		res, err := http.Get("http://127.0.0.1" + env("SIGNIN_ADDR", ":8080") + "/healthz")
		if err != nil || res.StatusCode != 200 {
			os.Exit(1)
		}
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: signin serve | check | newkey | healthz")
	os.Exit(2)
}

func serve(path string) error {
	cfg := NewConfigFile(path)
	if _, err := cfg.Get(); err != nil {
		// keeps running: the file is read again when it changes
		fmt.Fprintln(os.Stderr, "signin: not ready yet:", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	// SIGNIN_TRUSTED_PROXY: the reverse proxy's host name (caddy) or address. Only its
	// X-Forwarded-For is believed; unset, every visitor is taken at the connection's address.
	app := NewApp(cfg, NewEntries(2*time.Minute, 5000, 20), strings.TrimSpace(os.Getenv("SIGNIN_TRUSTED_PROXY")))
	srv := &http.Server{Addr: env("SIGNIN_ADDR", ":8080"), Handler: app.Routes(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, MaxHeaderBytes: 1 << 16}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(sctx)
	}()
	fmt.Println("signin: listening on", srv.Addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}
