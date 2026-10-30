package main

import (
	"errors"
	"net/url"
	"strings"
	"testing"
)

func TestSafeErrHidesAddresses(t *testing.T) {
	err := &url.Error{Op: "Post", URL: "https://api.push.apple.com/3/device/abc123token", Err: errors.New("dial tcp: lookup https://ntfy.sh/secret-topic failed")}
	got := safeErr(err)
	if strings.Contains(got, "abc123token") || strings.Contains(got, "secret-topic") {
		t.Fatalf("address leaked: %q", got)
	}
	if !strings.HasPrefix(got, "Post: ") {
		t.Fatalf("unexpected: %q", got)
	}
}
