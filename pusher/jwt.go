// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
)

var b64 = base64.RawURLEncoding

// signJWT builds a compact JWS. ES256 for *ecdsa.PrivateKey, RS256 for *rsa.PrivateKey.
func signJWT(key crypto.Signer, header, claims map[string]any) (string, error) {
	switch key.(type) {
	case *ecdsa.PrivateKey:
		header["alg"] = "ES256"
	case *rsa.PrivateKey:
		header["alg"] = "RS256"
	default:
		return "", errors.New("unsupported key type")
	}
	header["typ"] = "JWT"
	h, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	c, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signing := b64.EncodeToString(h) + "." + b64.EncodeToString(c)
	sum := sha256.Sum256([]byte(signing))

	var sig []byte
	switch k := key.(type) {
	case *ecdsa.PrivateKey:
		r, s, err := ecdsa.Sign(rand.Reader, k, sum[:])
		if err != nil {
			return "", err
		}
		// JWS ES256 wants fixed-width r||s, not ASN.1.
		sig = append(pad32(r), pad32(s)...)
	case *rsa.PrivateKey:
		sig, err = rsa.SignPKCS1v15(rand.Reader, k, crypto.SHA256, sum[:])
		if err != nil {
			return "", err
		}
	}
	return signing + "." + b64.EncodeToString(sig), nil
}

func pad32(n *big.Int) []byte {
	out := make([]byte, 32)
	n.FillBytes(out)
	return out
}

// parsePrivateKey reads a PEM private key (PKCS#8, or SEC1 EC, or PKCS#1 RSA).
func parsePrivateKey(pemBytes []byte) (crypto.Signer, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("no PEM block found")
	}
	if k, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if s, ok := k.(crypto.Signer); ok {
			return s, nil
		}
		return nil, errors.New("PKCS#8 key is not a signer")
	}
	if k, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	return nil, errors.New("unsupported private key format")
}
