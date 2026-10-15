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
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"
)

// WebPush delivers to UnifiedPush endpoints (or any Web Push endpoint) with
// RFC 8291 message encryption (aes128gcm) and optional RFC 8292 VAPID.
//
// The device "token" for this provider is a JSON object:
//
//	{"endpoint":"https://...","p256dh":"<base64url>","auth":"<base64url>"}
type WebPush struct {
	vapidKey     *ecdsa.PrivateKey
	vapidSubject string
	client       *http.Client
}

type webPushSub struct {
	Endpoint string `json:"endpoint"`
	P256dh   string `json:"p256dh"`
	Auth     string `json:"auth"`
}

// publicOnlyClient refuses to connect to loopback, private, link-local and other
// non-public addresses. Endpoints come from app registrations, so without this a
// registration could make the relay send requests into the server's own network.
// The check runs on the address actually dialled, after DNS, so it also covers names
// that resolve to private addresses. Redirects are not followed.
func publicOnlyClient(allowPrivate bool) *http.Client {
	dialer := &net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			if allowPrivate {
				return nil
			}
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip, err := netip.ParseAddr(host)
			if err != nil {
				return fmt.Errorf("refusing to dial %q", host)
			}
			if !isPublicAddr(ip) {
				return fmt.Errorf("refusing to dial non-public address %s", ip)
			}
			return nil
		},
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = dialer.DialContext
	transport.Proxy = nil
	return &http.Client{
		Timeout:   15 * time.Second,
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func isPublicAddr(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() {
		return false
	}
	for _, p := range nonPublic {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

var nonPublic = []netip.Prefix{
	netip.MustParsePrefix("100.64.0.0/10"), // carrier-grade NAT
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("2001:db8::/32"),
}

func newWebPushFromEnv() (*WebPush, error) {
	allowPrivate := os.Getenv("PUSHER_ALLOW_PRIVATE_ENDPOINTS") == "1"
	w := &WebPush{client: publicOnlyClient(allowPrivate), vapidSubject: os.Getenv("VAPID_SUBJECT")}
	if path := os.Getenv("VAPID_PRIVATE_KEY_FILE"); path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("vapid key: %w", err)
		}
		k, err := parsePrivateKey(raw)
		if err != nil {
			return nil, fmt.Errorf("vapid key: %w", err)
		}
		ek, ok := k.(*ecdsa.PrivateKey)
		if !ok || ek.Curve != elliptic.P256() {
			return nil, errors.New("vapid key must be EC P-256")
		}
		w.vapidKey = ek
		if w.vapidSubject == "" {
			return nil, errors.New("VAPID_SUBJECT (mailto: or https: contact) is required with a VAPID key")
		}
	}
	return w, nil
}

// VapidPublicKey returns the uncompressed public key, base64url, for apps to register with.
func (w *WebPush) VapidPublicKey() string {
	if w.vapidKey == nil {
		return ""
	}
	pk, err := w.vapidKey.PublicKey.ECDH()
	if err != nil {
		return ""
	}
	return b64.EncodeToString(pk.Bytes())
}

// encryptAes128gcm implements RFC 8291 section 3.4 and RFC 8188 with a single record.
func encryptAes128gcm(plaintext, uaPublic, authSecret []byte) ([]byte, error) {
	curve := ecdh.P256()
	ua, err := curve.NewPublicKey(uaPublic)
	if err != nil {
		return nil, fmt.Errorf("bad p256dh: %w", err)
	}
	if len(authSecret) != 16 {
		return nil, errors.New("auth secret must be 16 bytes")
	}
	asPriv, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return encryptWith(plaintext, ua, authSecret, asPriv, salt)
}

func encryptWith(plaintext []byte, ua *ecdh.PublicKey, authSecret []byte, asPriv *ecdh.PrivateKey, salt []byte) ([]byte, error) {
	asPublic := asPriv.PublicKey().Bytes()
	ecdhSecret, err := asPriv.ECDH(ua)
	if err != nil {
		return nil, err
	}
	keyInfo := "WebPush: info\x00" + string(ua.Bytes()) + string(asPublic)
	ikm, err := hkdf.Key(sha256.New, ecdhSecret, authSecret, keyInfo, 32)
	if err != nil {
		return nil, err
	}
	cek, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, err
	}
	nonce, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	padded := append(append([]byte{}, plaintext...), 0x02) // final-record delimiter
	ct := gcm.Seal(nil, nonce, padded, nil)

	var hdr bytes.Buffer
	hdr.Write(salt)
	_ = binary.Write(&hdr, binary.BigEndian, uint32(4096))
	hdr.WriteByte(byte(len(asPublic)))
	hdr.Write(asPublic)
	return append(hdr.Bytes(), ct...), nil
}

func (w *WebPush) vapidHeader(endpoint string) (string, error) {
	if w.vapidKey == nil {
		return "", nil
	}
	u, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	jwt, err := signJWT(w.vapidKey, map[string]any{}, map[string]any{
		"aud": u.Scheme + "://" + u.Host,
		"exp": time.Now().Add(12 * time.Hour).Unix(),
		"sub": w.vapidSubject,
	})
	if err != nil {
		return "", err
	}
	return "vapid t=" + jwt + ", k=" + w.VapidPublicKey(), nil
}

func (w *WebPush) Send(ctx context.Context, t Target, m Message) (Outcome, error) {
	var sub webPushSub
	if err := json.Unmarshal([]byte(t.Token), &sub); err != nil || sub.Endpoint == "" {
		return Invalid, nil
	}
	u, err := url.Parse(sub.Endpoint)
	if err != nil || u.Scheme != "https" {
		return Invalid, nil
	}
	pub, err1 := b64.DecodeString(strings.TrimRight(sub.P256dh, "="))
	auth, err2 := b64.DecodeString(strings.TrimRight(sub.Auth, "="))
	if err1 != nil || err2 != nil {
		return Invalid, nil
	}
	plain, _ := json.Marshal(map[string]any{"title": m.Title, "body": m.Body, "data": m.Data})
	body, err := encryptAes128gcm(plain, pub, auth)
	if err != nil {
		return Invalid, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return Failed, err
	}
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("TTL", "86400")
	req.Header.Set("Urgency", "high")
	if h, err := w.vapidHeader(sub.Endpoint); err == nil && h != "" {
		req.Header.Set("Authorization", h)
	}
	res, err := w.client.Do(req)
	if err != nil {
		return Failed, err
	}
	defer res.Body.Close()
	switch {
	case res.StatusCode >= 200 && res.StatusCode < 300:
		return Delivered, nil
	case res.StatusCode == http.StatusNotFound || res.StatusCode == http.StatusGone:
		return Invalid, nil
	default:
		return Failed, fmt.Errorf("webpush %d", res.StatusCode)
	}
}
