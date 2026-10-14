// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

// APNs sends to Apple Push Notification service with token (.p8) authentication.
type APNs struct {
	KeyID, TeamID, Topic string
	key                  *ecdsa.PrivateKey
	client               *http.Client
	ProdURL, SandboxURL  string

	mu        sync.Mutex
	token     string
	tokenTime time.Time
}

func newAPNsFromEnv() (*APNs, error) {
	path := os.Getenv("APNS_KEY_FILE")
	if path == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	signer, err := parsePrivateKey(raw)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	k, ok := signer.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("apns key must be an EC P-256 key (.p8)")
	}
	a := &APNs{
		KeyID:      os.Getenv("APNS_KEY_ID"),
		TeamID:     os.Getenv("APNS_TEAM_ID"),
		Topic:      os.Getenv("APNS_TOPIC"),
		key:        k,
		client:     &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{ForceAttemptHTTP2: true}},
		ProdURL:    "https://api.push.apple.com",
		SandboxURL: "https://api.sandbox.push.apple.com",
	}
	if a.KeyID == "" || a.TeamID == "" || a.Topic == "" {
		return nil, fmt.Errorf("APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC are required with APNS_KEY_FILE")
	}
	return a, nil
}

// providerToken returns a cached JWT; Apple asks for refresh between 20 and 60 minutes.
func (a *APNs) providerToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.token != "" && time.Since(a.tokenTime) < 40*time.Minute {
		return a.token, nil
	}
	now := time.Now()
	t, err := signJWT(a.key, map[string]any{"kid": a.KeyID}, map[string]any{"iss": a.TeamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	a.token, a.tokenTime = t, now
	return t, nil
}

func (a *APNs) Send(ctx context.Context, t Target, m Message) (Outcome, error) {
	jwt, err := a.providerToken()
	if err != nil {
		return Failed, err
	}
	payload := map[string]any{
		"aps": map[string]any{
			"alert": map[string]string{"title": m.Title, "body": m.Body},
			"sound": "default",
		},
	}
	for k, v := range m.Data {
		payload[k] = v
	}
	body, _ := json.Marshal(payload)
	base := a.ProdURL
	if t.Sandbox {
		base = a.SandboxURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+t.Token, bytes.NewReader(body))
	if err != nil {
		return Failed, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", a.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(24*time.Hour).Unix()))
	res, err := a.client.Do(req)
	if err != nil {
		return Failed, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return Delivered, nil
	}
	var reason struct {
		Reason string `json:"reason"`
	}
	data, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	_ = json.Unmarshal(data, &reason)
	if res.StatusCode == http.StatusGone || reason.Reason == "BadDeviceToken" || reason.Reason == "Unregistered" || reason.Reason == "DeviceTokenNotForTopic" {
		return Invalid, nil
	}
	return Failed, fmt.Errorf("apns %d %s", res.StatusCode, reason.Reason)
}
