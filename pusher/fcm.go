// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"crypto"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// FCM sends to Android phones through Firebase Cloud Messaging HTTP v1, with the service-account
// key of OpenWorks IT's Firebase project (FCM_CREDENTIALS_FILE, deploy/secrets/fcm.json).
type FCM struct {
	projectID, clientEmail, tokenURI string
	key                              crypto.Signer
	client                           *http.Client
	SendURL                          string

	mu        sync.Mutex
	access    string
	accessExp time.Time
}

func newFCMFromEnv() (*FCM, error) {
	path := os.Getenv("FCM_CREDENTIALS_FILE")
	if path == "" {
		return nil, nil
	}
	// a missing file comes back as fs.ErrNotExist: FCM is off and the relay carries on
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("fcm credentials: %w", err)
	}
	var sa struct {
		Type        string `json:"type"`
		ProjectID   string `json:"project_id"`
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if err := json.Unmarshal(raw, &sa); err != nil {
		return nil, fmt.Errorf("fcm credentials: %w", err)
	}
	if sa.Type != "service_account" || sa.ProjectID == "" || sa.ClientEmail == "" {
		return nil, fmt.Errorf("fcm credentials: %s isn't a service-account key (Firebase console > Project settings > Service accounts > Generate new private key; google-services.json doesn't go on servers)", path)
	}
	key, err := parsePrivateKey([]byte(sa.PrivateKey))
	if err != nil {
		return nil, fmt.Errorf("fcm credentials: %w", err)
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &FCM{
		projectID: sa.ProjectID, clientEmail: sa.ClientEmail, tokenURI: sa.TokenURI, key: key,
		client:  &http.Client{Timeout: 15 * time.Second},
		SendURL: "https://fcm.googleapis.com/v1/projects/" + sa.ProjectID + "/messages:send",
	}, nil
}

func (f *FCM) accessToken(ctx context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.access != "" && time.Until(f.accessExp) > 2*time.Minute {
		return f.access, nil
	}
	now := time.Now()
	assertion, err := signJWT(f.key, map[string]any{}, map[string]any{
		"iss": f.clientEmail, "scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud": f.tokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, f.tokenURI, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := f.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(res.Body).Decode(&tok); err != nil || tok.AccessToken == "" {
		return "", fmt.Errorf("fcm oauth failed (%d)", res.StatusCode)
	}
	f.access, f.accessExp = tok.AccessToken, now.Add(time.Duration(tok.ExpiresIn)*time.Second)
	return f.access, nil
}

// fcmPayload is the whole message Google gets: the device's token, the notification's words,
// and when to give up (a day, as for Apple). No "data", no collapse key, no tag.
func fcmPayload(token string) []byte {
	type notification struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	type android struct {
		Priority string `json:"priority"`
		TTL      string `json:"ttl"`
	}
	type message struct {
		Token        string       `json:"token"`
		Notification notification `json:"notification"`
		Android      android      `json:"android"`
	}
	body, _ := json.Marshal(struct {
		Message message `json:"message"`
	}{message{token, notification{noticeTitle, noticeBody}, android{"high", "86400s"}}})
	return body
}

func (f *FCM) Send(ctx context.Context, t Target) (Outcome, error) {
	access, err := f.accessToken(ctx)
	if err != nil {
		return Failed, err
	}
	body := fcmPayload(t.Token)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, f.SendURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.client.Do(req)
	if err != nil {
		return Failed, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return Delivered, nil
	}
	data, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	if res.StatusCode == http.StatusNotFound || strings.Contains(string(data), "UNREGISTERED") {
		return Invalid, nil
	}
	return Failed, fmt.Errorf("fcm %d", res.StatusCode)
}
