// Steady push relay.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A small internal service that the Steady server calls to deliver notifications to iPhones
// (Apple, APNs) and Android phones (Google, Firebase Cloud Messaging). Every notification is
// the same: titled "Steady", saying "New notification". The server tells the relay only which
// devices to notify, never who or why, and the relay adds nothing else: no kind, no ids, no
// data keys. The app loads what's new over its own connection when it's opened.
// Standard library only.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// The words on every notification. They are the whole message: nothing from the server's
// request reaches Apple or Google except the device's own token.
const (
	noticeTitle = "Steady"
	noticeBody  = "New notification"
)

type Target struct {
	ID       string `json:"id"`
	Provider string `json:"provider"`
	Token    string `json:"token"`
	Sandbox  bool   `json:"sandbox"`
}

// sendRequest is all the relay reads from the server: which devices. Anything else in the
// request (older servers also sent a title, a body and the notification's kind) is ignored.
type sendRequest struct {
	Targets []Target `json:"targets"`
}

type sendResponse struct {
	Sent    int      `json:"sent"`
	Failed  int      `json:"failed"`
	Invalid []string `json:"invalid"`
}

type Outcome int

const (
	Delivered Outcome = iota
	Failed
	Invalid
)

// A Sender delivers the one notification there is to one device. It is given the device and
// nothing else, so there is no way for anything about the person to reach the payload.
type Sender interface {
	Send(ctx context.Context, t Target) (Outcome, error)
}

type Server struct {
	Secret    string
	Providers map[string]Sender
	Logger    *log.Logger
}

const maxTargets = 50

// Sends go out at once (a few at a time), each given perTarget and all of them perRequest:
// the server waits 10 seconds for the answer, and one slow or stalling answer from Apple or
// Google must not hold up the others or the server's request.
const (
	perTarget  = 4 * time.Second
	perRequest = 8 * time.Second
	parallel   = 10
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /send", s.handleSend)
	return mux
}

func (s *Server) authorised(r *http.Request) bool {
	got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	return s.Secret != "" && subtle.ConstantTimeCompare([]byte(got), []byte(s.Secret)) == 1
}

func (s *Server) handleSend(w http.ResponseWriter, r *http.Request) {
	if !s.authorised(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorised"})
		return
	}
	var req sendRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if len(req.Targets) > maxTargets {
		req.Targets = req.Targets[:maxTargets]
	}
	out := sendResponse{Invalid: []string{}}
	ctx, cancel := context.WithTimeout(r.Context(), perRequest)
	defer cancel()
	type result struct {
		res Outcome
		err error
	}
	results := make([]result, len(req.Targets))
	slots := make(chan struct{}, parallel)
	var wg sync.WaitGroup
	for i, t := range req.Targets {
		p, ok := s.Providers[t.Provider]
		if !ok || p == nil {
			results[i] = result{Failed, nil}
			continue
		}
		wg.Add(1)
		go func(i int, t Target, p Sender) {
			defer wg.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[i] = result{Failed, ctx.Err()}
				return
			}
			tctx, tcancel := context.WithTimeout(ctx, perTarget)
			defer tcancel()
			res, err := p.Send(tctx, t)
			results[i] = result{res, err}
		}(i, t, p)
	}
	wg.Wait()
	for i, t := range req.Targets {
		switch results[i].res {
		case Delivered:
			out.Sent++
		case Invalid:
			out.Invalid = append(out.Invalid, t.ID)
		default:
			out.Failed++
			if err := results[i].err; err != nil && s.Logger != nil {
				// never log tokens: a network error's text holds the whole address (an APNs
				// device token is part of it), so log only what went wrong
				s.Logger.Printf("send via %s failed: %s", t.Provider, safeErr(err))
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	logger := log.New(os.Stderr, "pusher ", log.LstdFlags)
	secret := os.Getenv("PUSHER_SECRET")
	if len(secret) < 24 {
		logger.Fatal("PUSHER_SECRET must be set (24+ characters)")
	}
	providers := map[string]Sender{}
	apns, err := newAPNsFromEnv()
	if err != nil {
		logger.Fatal(err)
	}
	if apns != nil {
		providers["apns"] = apns
		logger.Print("APNs enabled")
	}
	fcm, err := newFCMFromEnv()
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// expected until the server has its Firebase key: iPhones still get their notifications
		logger.Printf("FCM off: no %s (Android phones get no notifications; docs/DEPLOY.md, step 3a)", os.Getenv("FCM_CREDENTIALS_FILE"))
	case err != nil:
		logger.Fatal(err)
	case fcm != nil:
		providers["fcm"] = fcm
		logger.Print("FCM enabled")
	}
	if len(providers) == 0 {
		logger.Print("no push providers set up: phones get no notifications")
	}

	addr := os.Getenv("PUSHER_ADDR")
	if addr == "" {
		addr = ":8090"
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           (&Server{Secret: secret, Providers: providers, Logger: logger}).routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      45 * time.Second,
	}
	logger.Printf("listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatal(err)
	}
}

// safeErr describes an error without any address in it (see the comment where it's used).
func safeErr(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		inner := ue.Err
		var ne net.Error
		if errors.As(inner, &ne) && ne.Timeout() {
			return ue.Op + ": timeout"
		}
		return ue.Op + ": " + scrubURLs(inner.Error())
	}
	return scrubURLs(err.Error())
}

var urlPattern = regexp.MustCompile(`https?://[^\s"']+`)

func scrubURLs(s string) string { return urlPattern.ReplaceAllString(s, "<address>") }
