// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// decryptAes128gcm is an independent receiver-side implementation of RFC 8291/8188.
func decryptAes128gcm(t *testing.T, body []byte, uaPriv *ecdh.PrivateKey, auth []byte) []byte {
	t.Helper()
	salt := body[:16]
	rs := binary.BigEndian.Uint32(body[16:20])
	if rs != 4096 {
		t.Fatalf("record size %d", rs)
	}
	idlen := int(body[20])
	asPubBytes := body[21 : 21+idlen]
	ct := body[21+idlen:]
	asPub, err := ecdh.P256().NewPublicKey(asPubBytes)
	if err != nil {
		t.Fatal(err)
	}
	secret, err := uaPriv.ECDH(asPub)
	if err != nil {
		t.Fatal(err)
	}
	prkKey, _ := hkdf.Extract(sha256.New, secret, auth)
	ikm, _ := hkdf.Expand(sha256.New, prkKey, "WebPush: info\x00"+string(uaPriv.PublicKey().Bytes())+string(asPubBytes), 32)
	prk, _ := hkdf.Extract(sha256.New, ikm, salt)
	cek, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	block, _ := aes.NewCipher(cek)
	gcm, _ := cipher.NewGCM(block)
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if pt[len(pt)-1] != 0x02 {
		t.Fatalf("missing final-record delimiter")
	}
	return pt[:len(pt)-1]
}

func TestWebPushEncryptionRoundTrip(t *testing.T) {
	ua, _ := ecdh.P256().GenerateKey(rand.Reader)
	auth := make([]byte, 16)
	rand.Read(auth)
	msg := []byte(`{"title":"Steady","body":"You have a new update."}`)
	body, err := encryptAes128gcm(msg, ua.PublicKey().Bytes(), auth)
	if err != nil {
		t.Fatal(err)
	}
	if got := decryptAes128gcm(t, body, ua, auth); !bytes.Equal(got, msg) {
		t.Fatalf("round trip mismatch: %s", got)
	}
	if _, err := encryptAes128gcm(msg, []byte("nope"), auth); err == nil {
		t.Fatal("expected bad key error")
	}
}

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

func (f *fakeSender) Send(ctx context.Context, t Target, m Message) (Outcome, error) {
	f.got = append(f.got, t)
	return f.result, nil
}

func TestSendEndpoint(t *testing.T) {
	ok := &fakeSender{result: Delivered}
	gone := &fakeSender{result: Invalid}
	s := &Server{Secret: "0123456789abcdef01234567", Providers: map[string]Sender{"apns": ok, "unifiedpush": gone}}
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
	body := `{"title":"Steady","body":"You have a new update.","data":{"kind":"checkin"},
	  "targets":[{"id":"d1","provider":"apns","token":"t1"},{"id":"d2","provider":"unifiedpush","token":"{}"},{"id":"d3","provider":"fcm","token":"x"}]}`
	res, out := post(s.Secret, body)
	if res.StatusCode != 200 || out.Sent != 1 || out.Failed != 1 || len(out.Invalid) != 1 || out.Invalid[0] != "d2" {
		t.Fatalf("unexpected %d %+v", res.StatusCode, out)
	}
}

func TestClampMessage(t *testing.T) {
	m := clampMessage(Message{Title: strings.Repeat("x", 200), Body: strings.Repeat("y", 500)})
	if len(m.Title) != 60 || len(m.Body) != 160 {
		t.Fatal("not clamped")
	}
}

func TestWebPushSendToEndpoint(t *testing.T) {
	ua, _ := ecdh.P256().GenerateKey(rand.Reader)
	auth := make([]byte, 16)
	rand.Read(auth)
	var received []byte
	var headers http.Header
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received, _ = io.ReadAll(r.Body)
		headers = r.Header.Clone()
		w.WriteHeader(201)
	}))
	defer ts.Close()

	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wp := &WebPush{client: ts.Client(), vapidKey: k, vapidSubject: "mailto:it@example.org"}
	sub, _ := json.Marshal(webPushSub{Endpoint: ts.URL + "/up/abc", P256dh: b64.EncodeToString(ua.PublicKey().Bytes()), Auth: b64.EncodeToString(auth)})
	res, err := wp.Send(context.Background(), Target{ID: "d", Provider: "unifiedpush", Token: string(sub)}, Message{Title: "Steady", Body: "You have a new update.", Data: map[string]string{"kind": "assigned"}})
	if err != nil || res != Delivered {
		t.Fatalf("send: %v %v", res, err)
	}
	if headers.Get("Content-Encoding") != "aes128gcm" || !strings.HasPrefix(headers.Get("Authorization"), "vapid t=") {
		t.Fatalf("headers %v", headers)
	}
	var msg Message
	if err := json.Unmarshal(decryptAes128gcm(t, received, ua, auth), &msg); err != nil || msg.Body != "You have a new update." {
		t.Fatalf("payload %v %v", msg, err)
	}
	// http endpoints are refused
	bad, _ := json.Marshal(webPushSub{Endpoint: "http://example.org/x", P256dh: "a", Auth: "b"})
	if r, _ := wp.Send(context.Background(), Target{Token: string(bad)}, Message{}); r != Invalid {
		t.Fatal("http endpoint should be invalid")
	}
}

func TestAPNsSendAgainstFakeServer(t *testing.T) {
	var path, topic, authz string
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, topic, authz = r.URL.Path, r.Header.Get("apns-topic"), r.Header.Get("authorization")
		if strings.HasSuffix(r.URL.Path, "/gone") {
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
	res, err := a.Send(context.Background(), Target{Token: "abc"}, Message{Title: "Steady", Body: "x"})
	if err != nil || res != Delivered || path != "/3/device/abc" || topic != "za.co.openworks.steady" || !strings.HasPrefix(authz, "bearer ") {
		t.Fatalf("%v %v %s %s %s", res, err, path, topic, authz)
	}
	if res, _ := a.Send(context.Background(), Target{Token: "gone"}, Message{}); res != Invalid {
		t.Fatal("410 should mark the token invalid")
	}
}

func TestNewWebPushFromEnvLoadsVapid(t *testing.T) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalECPrivateKey(k)
	p := filepath.Join(t.TempDir(), "vapid.pem")
	os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600)
	t.Setenv("VAPID_PRIVATE_KEY_FILE", p)
	t.Setenv("VAPID_SUBJECT", "mailto:it@example.org")
	wp, err := newWebPushFromEnv()
	if err != nil || len(wp.VapidPublicKey()) < 80 {
		t.Fatalf("vapid: %v %q", err, wp.VapidPublicKey())
	}
}
