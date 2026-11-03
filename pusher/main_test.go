// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"io/fs"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestES256JWTVerifies(t *testing.T) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tok, err := signJWT(k, map[string]any{"kid": "ABC"}, map[string]any{"iss": "TEAM"})
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatal("bad jwt")
	}
	sig, _ := b64.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("ES256 signature must be 64 bytes, got %d", len(sig))
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&k.PublicKey, sum[:], r, s) {
		t.Fatal("signature does not verify")
	}
	var hdr map[string]any
	h, _ := b64.DecodeString(parts[0])
	json.Unmarshal(h, &hdr)
	if hdr["alg"] != "ES256" || hdr["kid"] != "ABC" {
		t.Fatalf("header %v", hdr)
	}
}

func TestParseKeys(t *testing.T) {
	ek, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(ek)
	p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if k, err := parsePrivateKey(p8); err != nil || k == nil {
		t.Fatalf("p8: %v", err)
	}
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	rder := x509.MarshalPKCS1PrivateKey(rk)
	if _, err := parsePrivateKey(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: rder})); err != nil {
		t.Fatalf("rsa: %v", err)
	}
	if _, err := parsePrivateKey([]byte("garbage")); err == nil {
		t.Fatal("expected error")
	}
}

type fakeSender struct {
	got    []Target
	result Outcome
}

func (f *fakeSender) Send(ctx context.Context, t Target) (Outcome, error) {
	f.got = append(f.got, t)
	return f.result, nil
}

func TestSendEndpoint(t *testing.T) {
	ok := &fakeSender{result: Delivered}
	gone := &fakeSender{result: Invalid}
	s := &Server{Secret: "0123456789abcdef01234567", Providers: map[string]Sender{"apns": ok, "fcm": gone}}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	post := func(secret, body string) (*http.Response, sendResponse) {
		req, _ := http.NewRequest("POST", ts.URL+"/send", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var out sendResponse
		data, _ := io.ReadAll(res.Body)
		json.Unmarshal(data, &out)
		return res, out
	}
	if res, _ := post("wrong", `{}`); res.StatusCode != 401 {
		t.Fatalf("want 401, got %d", res.StatusCode)
	}
	// an old phone's UnifiedPush registration: no such provider any more, so it isn't sent
	body := `{"targets":[{"id":"d1","provider":"apns","token":"t1"},{"id":"d2","provider":"fcm","token":"x"},{"id":"d3","provider":"unifiedpush","token":"{}"}]}`
	res, out := post(s.Secret, body)
	if res.StatusCode != 200 || out.Sent != 1 || out.Failed != 1 || len(out.Invalid) != 1 || out.Invalid[0] != "d2" {
		t.Fatalf("unexpected %d %+v", res.StatusCode, out)
	}
}

// The whole of what Apple and Google get, byte for byte: the words and nothing else.
const (
	wantAPNs = `{"aps":{"alert":{"title":"Steady","body":"New notification"},"sound":"default"}}`
	wantFCM  = `{"message":{"token":"%s","notification":{"title":"Steady","body":"New notification"},"android":{"priority":"high","ttl":"86400s"}}}`
)

func TestPayloadsCarryOnlyTheWords(t *testing.T) {
	if got := string(apnsPayload()); got != wantAPNs {
		t.Fatalf("APNs\n got %s\nwant %s", got, wantAPNs)
	}
	if got, want := string(fcmPayload("tok")), strings.Replace(wantFCM, "%s", "tok", 1); got != want {
		t.Fatalf("FCM\n got %s\nwant %s", got, want)
	}
	// and structurally: Apple gets "aps" only, Google gets no "data" (or anything else) at all
	var a map[string]map[string]any
	json.Unmarshal(apnsPayload(), &a)
	if len(a) != 1 || len(a["aps"]) != 2 {
		t.Fatalf("APNs keys: %v", a)
	}
	var f map[string]map[string]any
	json.Unmarshal(fcmPayload("tok"), &f)
	if len(f) != 1 || len(f["message"]) != 3 || f["message"]["data"] != nil {
		t.Fatalf("FCM keys: %v", f)
	}
}

func TestAPNsSendAgainstFakeServer(t *testing.T) {
	ok, gone := strings.Repeat("ab", 32), strings.Repeat("cd", 32)
	var path, topic, authz string
	var body []byte
	var headers http.Header
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, topic, authz = r.URL.Path, r.Header.Get("apns-topic"), r.Header.Get("authorization")
		body, _ = io.ReadAll(r.Body)
		headers = r.Header.Clone()
		if strings.HasSuffix(r.URL.Path, gone) {
			w.WriteHeader(410)
			w.Write([]byte(`{"reason":"Unregistered"}`))
			return
		}
		w.WriteHeader(200)
	}))
	ts.EnableHTTP2 = true
	ts.StartTLS()
	defer ts.Close()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	a := &APNs{KeyID: "KID", TeamID: "TEAM", Topic: "za.co.openworks.steady", key: k, client: ts.Client(), ProdURL: ts.URL, SandboxURL: ts.URL}
	res, err := a.Send(context.Background(), Target{Token: ok})
	if err != nil || res != Delivered || path != "/3/device/"+ok || topic != "za.co.openworks.steady" || !strings.HasPrefix(authz, "bearer ") {
		t.Fatalf("%v %v %s %s %s", res, err, path, topic, authz)
	}
	if string(body) != wantAPNs {
		t.Fatalf("APNs payload\n got %s\nwant %s", body, wantAPNs)
	}
	for _, h := range []string{"apns-collapse-id", "apns-id"} {
		if headers.Get(h) != "" {
			t.Fatalf("%s must not be set: %q", h, headers.Get(h))
		}
	}
	if res, _ := a.Send(context.Background(), Target{Token: gone}); res != Invalid {
		t.Fatal("410 should mark the token invalid")
	}
	// anything but a hex token never reaches Apple (it would go into the request's path)
	path = ""
	if res, _ := a.Send(context.Background(), Target{Token: "../../../x"}); res != Invalid || path != "" {
		t.Fatalf("a malformed token should be invalid without a request: %v %q", res, path)
	}
}

// One stalling device server must not hold up the others, or the answer the server waits for.
type stallSender struct{}

func (stallSender) Send(ctx context.Context, t Target) (Outcome, error) {
	if t.Token == "stall" {
		<-ctx.Done()
		return Failed, ctx.Err()
	}
	return Delivered, nil
}

func TestSendDoesNotWaitForAStallingDevice(t *testing.T) {
	s := &Server{Secret: "secret-secret-secret-secret", Providers: map[string]Sender{"fcm": stallSender{}}}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()
	targets := []string{}
	for i := 0; i < maxTargets; i++ {
		tok := "ok"
		if i%5 == 0 {
			tok = "stall"
		}
		targets = append(targets, `{"id":"d`+strconv.Itoa(i)+`","provider":"fcm","token":"`+tok+`"}`)
	}
	req, _ := http.NewRequest("POST", ts.URL+"/send", strings.NewReader(`{"targets":[`+strings.Join(targets, ",")+`]}`))
	req.Header.Set("Authorization", "Bearer "+s.Secret)
	start := time.Now()
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out sendResponse
	json.NewDecoder(res.Body).Decode(&out)
	took := time.Since(start)
	if took > perRequest+time.Second {
		t.Fatalf("took %v: the server waits 10s", took)
	}
	if out.Sent != 40 || out.Failed != 10 {
		t.Fatalf("unexpected %+v after %v", out, took)
	}
}

// a fake of Google's two endpoints: the OAuth token exchange and FCM's send
type fakeGoogle struct {
	mu      sync.Mutex
	grant   url.Values
	authz   string
	bodies  []string
	answers map[string]int // token -> status for the send
}

func (g *fakeGoogle) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if r.URL.Path == "/token" {
		r.ParseForm()
		g.grant = r.PostForm
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"access_token":"ya29.test","expires_in":3600}`))
		return
	}
	b, _ := io.ReadAll(r.Body)
	g.bodies = append(g.bodies, string(b))
	g.authz = r.Header.Get("Authorization")
	var m struct {
		Message struct {
			Token string `json:"token"`
		} `json:"message"`
	}
	json.Unmarshal(b, &m)
	switch g.answers[m.Message.Token] {
	case 404:
		w.WriteHeader(404)
		w.Write([]byte(`{"error":{"code":404,"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
	case 500:
		w.WriteHeader(500)
	default:
		w.Write([]byte(`{"name":"projects/steady-test/messages/1"}`))
	}
}

func newTestFCM(t *testing.T, g *fakeGoogle) *FCM {
	t.Helper()
	ts := httptest.NewTLSServer(g)
	t.Cleanup(ts.Close)
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	return &FCM{projectID: "steady-test", clientEmail: "relay@steady-test.iam.gserviceaccount.com", tokenURI: ts.URL + "/token",
		key: k, client: ts.Client(), SendURL: ts.URL + "/v1/projects/steady-test/messages:send"}
}

func TestFCMSendAgainstFakeServer(t *testing.T) {
	g := &fakeGoogle{answers: map[string]int{"gone-token-gone-token": 404, "busy-token-busy-token": 500}}
	f := newTestFCM(t, g)
	res, err := f.Send(context.Background(), Target{Token: "fcm-token-fcm-token-1"})
	if err != nil || res != Delivered {
		t.Fatalf("send: %v %v", res, err)
	}
	if g.grant.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || strings.Count(g.grant.Get("assertion"), ".") != 2 {
		t.Fatalf("oauth grant %v", g.grant)
	}
	claims, _ := b64.DecodeString(strings.Split(g.grant.Get("assertion"), ".")[1])
	if !strings.Contains(string(claims), "firebase.messaging") {
		t.Fatalf("scope: %s", claims)
	}
	if g.authz != "Bearer ya29.test" {
		t.Fatalf("authorization %q", g.authz)
	}
	if want := strings.Replace(wantFCM, "%s", "fcm-token-fcm-token-1", 1); g.bodies[0] != want {
		t.Fatalf("FCM payload\n got %s\nwant %s", g.bodies[0], want)
	}
	if res, _ := f.Send(context.Background(), Target{Token: "gone-token-gone-token"}); res != Invalid {
		t.Fatal("UNREGISTERED should mark the token invalid")
	}
	if res, _ := f.Send(context.Background(), Target{Token: "busy-token-busy-token"}); res != Failed {
		t.Fatal("a 500 is a failure, not a dead token")
	}
}

func TestNewFCMFromEnv(t *testing.T) {
	dir := t.TempDir()
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	sa, _ := json.Marshal(map[string]string{
		"type": "service_account", "project_id": "steady-test", "client_email": "relay@steady-test.iam.gserviceaccount.com",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "token_uri": "https://oauth2.googleapis.com/token",
	})
	good := filepath.Join(dir, "fcm.json")
	os.WriteFile(good, sa, 0o600)
	t.Setenv("FCM_CREDENTIALS_FILE", good)
	f, err := newFCMFromEnv()
	if err != nil || f == nil || f.SendURL != "https://fcm.googleapis.com/v1/projects/steady-test/messages:send" {
		t.Fatalf("service account: %v %+v", err, f)
	}
	// no file yet: FCM is off and the relay carries on (main logs it), it doesn't stop
	t.Setenv("FCM_CREDENTIALS_FILE", filepath.Join(dir, "missing.json"))
	if _, err := newFCMFromEnv(); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing file: %v", err)
	}
	// the app's google-services.json by mistake: a clear error
	wrong := filepath.Join(dir, "google-services.json")
	os.WriteFile(wrong, []byte(`{"project_info":{"project_id":"steady-test"},"client":[]}`), 0o600)
	t.Setenv("FCM_CREDENTIALS_FILE", wrong)
	if _, err := newFCMFromEnv(); err == nil || !strings.Contains(err.Error(), "service-account") {
		t.Fatalf("google-services.json: %v", err)
	}
	t.Setenv("FCM_CREDENTIALS_FILE", "")
	if f, err := newFCMFromEnv(); f != nil || err != nil {
		t.Fatalf("unset: %v %v", f, err)
	}
}

// Whatever the server's request holds (an older server sent a title, a body and the kind),
// Apple and Google get the words and the device's token, nothing else.
func TestSendPassesNothingFromTheRequestOn(t *testing.T) {
	var mu sync.Mutex
	var apnsBodies []string
	apple := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		apnsBodies = append(apnsBodies, string(b)+" "+r.Header.Get("apns-collapse-id")+r.Header.Get("apns-thread-id"))
		mu.Unlock()
	}))
	apple.EnableHTTP2 = true
	apple.StartTLS()
	defer apple.Close()
	ek, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	a := &APNs{KeyID: "KID", TeamID: "TEAM", Topic: "za.co.openworks.steady", key: ek, client: apple.Client(), ProdURL: apple.URL, SandboxURL: apple.URL}
	g := &fakeGoogle{}
	s := &Server{Secret: "0123456789abcdef01234567", Providers: map[string]Sender{"apns": a, "fcm": newTestFCM(t, g)}}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()
	iphone := strings.Repeat("ef", 32)
	body := `{"title":"Lerato M","body":"PHQ-9 score 22, item 9","data":{"kind":"checkin","patient":"r123"},"kind":"checkin",
	  "targets":[{"id":"d1","provider":"apns","token":"` + iphone + `"},{"id":"d2","provider":"fcm","token":"android-token-android-1"}]}`
	req, _ := http.NewRequest("POST", ts.URL+"/send", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.Secret)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out sendResponse
	json.NewDecoder(res.Body).Decode(&out)
	res.Body.Close()
	if out.Sent != 2 {
		t.Fatalf("sent %+v", out)
	}
	if len(apnsBodies) != 1 || apnsBodies[0] != wantAPNs+" " {
		t.Fatalf("Apple got %q", apnsBodies)
	}
	if want := strings.Replace(wantFCM, "%s", "android-token-android-1", 1); len(g.bodies) != 1 || g.bodies[0] != want {
		t.Fatalf("Google got %q", g.bodies)
	}
	for _, got := range append(apnsBodies, g.bodies...) {
		for _, leak := range []string{"Lerato", "PHQ", "checkin", "r123", "kind", "data"} {
			if strings.Contains(got, leak) {
				t.Fatalf("%q reached a payload: %s", leak, got)
			}
		}
	}
}
