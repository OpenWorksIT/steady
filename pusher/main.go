// Steady push relay.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A small internal service that the Steady server calls to deliver notifications to
// Apple (APNs), UnifiedPush/Web Push and, optionally, Firebase (FCM). It only ever
// receives a generic title and body: never patient names, scores or text.
// Standard library only.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
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

type Target struct {
	ID       string `json:"id"`
	Provider string `json:"provider"`
	Token    string `json:"token"`
	Sandbox  bool   `json:"sandbox"`
}

type Message struct {
	Title string            `json:"title"`
	Body  string            `json:"body"`
	Data  map[string]string `json:"data"`
}

type sendRequest struct {
	Targets []Target `json:"targets"`
	Message
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

type Sender interface {
	Send(ctx context.Context, t Target, m Message) (Outcome, error)
}

type Server struct {
	Secret    string
	Providers map[string]Sender
	Logger    *log.Logger
	WebPush   *WebPush
}

const maxTargets = 50

// Sends go out at once (a few at a time), each given perTarget and all of them perRequest:
// the server waits 10 seconds for the answer, and one slow or stalling device server (Web
// Push endpoints are chosen by whoever registered the device) must not hold up the others or
// the server's request.
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
	mux.HandleFunc("GET /vapid-public-key", func(w http.ResponseWriter, r *http.Request) {
		key := ""
		if s.WebPush != nil {
			key = s.WebPush.VapidPublicKey()
		}
		writeJSON(w, http.StatusOK, map[string]string{"publicKey": key})
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
	req.Message = clampMessage(req.Message)
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
			res, err := p.Send(tctx, t, req.Message)
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
				// device token, a UnifiedPush topic), so log only what went wrong
				s.Logger.Printf("send via %s failed: %s", t.Provider, safeErr(err))
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func clampMessage(m Message) Message {
	clip := func(s string, n int) string {
		r := []rune(s)
		if len(r) > n {
			return string(r[:n])
		}
		return s
	}
	m.Title = clip(m.Title, 60)
	m.Body = clip(m.Body, 160)
	clean := map[string]string{}
	for k, v := range m.Data {
		if len(clean) >= 8 {
			break
		}
		clean[clip(k, 32)] = clip(v, 64)
	}
	m.Data = clean
	return m
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
	if err != nil {
		logger.Fatal(err)
	}
	if fcm != nil {
		providers["fcm"] = fcm
		logger.Print("FCM enabled")
	}
	wp, err := newWebPushFromEnv()
	if err != nil {
		logger.Fatal(err)
	}
	providers["unifiedpush"] = wp
	logger.Printf("UnifiedPush enabled (VAPID %v)", wp.vapidKey != nil)

	addr := os.Getenv("PUSHER_ADDR")
	if addr == "" {
		addr = ":8090"
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           (&Server{Secret: secret, Providers: providers, Logger: logger, WebPush: wp}).routes(),
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
