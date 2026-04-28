package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net"
	"net/http"
	"time"
)

var (
	clientSecrets = map[string]string{
		"app.test123": "test_secret_123",
	}
	authCodes = make(map[string]time.Time)
)

func randomString(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func authorizeHandler(w http.ResponseWriter, r *http.Request) {
	clientID := r.URL.Query().Get("client_id")
	redirectURI := r.URL.Query().Get("redirect_uri")
	state := r.URL.Query().Get("state")

	if clientID == "" || redirectURI == "" {
		http.Error(w, "missing client_id or redirect_uri", http.StatusBadRequest)
		return
	}

	code := randomString(32)
	authCodes[code] = time.Now().Add(5 * time.Minute)

	redirect := redirectURI + "?code=" + code
	if state != "" {
		redirect += "&state=" + state
	}
	http.Redirect(w, r, redirect, http.StatusFound)
}

func tokenHandler(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	grantType := r.Form.Get("grant_type")
	clientID := r.Form.Get("client_id")
	clientSecret := r.Form.Get("client_secret")

	if clientID == "" || clientSecret == "" {
		http.Error(w, "missing client_id or client_secret", http.StatusBadRequest)
		return
	}

	expectedSecret, ok := clientSecrets[clientID]
	if !ok || expectedSecret != clientSecret {
		http.Error(w, "invalid client_id or client_secret", http.StatusUnauthorized)
		return
	}

	resp := map[string]interface{}{
		"client_endpoint":  "https://portal.test.bitrix24.com/rest/",
		"server_endpoint":  "https://oauth.test.bitrix24.com/rest/",
		"domain":           "oauth.test.bitrix24.com",
		"expires_in":       3600,
		"member_id":        randomString(32),
		"scope":            "app",
		"status":           "T",
	}

	switch grantType {
	case "authorization_code":
		code := r.Form.Get("code")
		if code == "" {
			http.Error(w, "missing code", http.StatusBadRequest)
			return
		}
		exp, ok := authCodes[code]
		if !ok || time.Now().After(exp) {
			http.Error(w, "invalid or expired code", http.StatusBadRequest)
			return
		}
		delete(authCodes, code)
		resp["access_token"] = randomString(48)
		resp["refresh_token"] = randomString(48)

	case "refresh_token":
		refreshToken := r.Form.Get("refresh_token")
		if refreshToken == "" {
			http.Error(w, "missing refresh_token", http.StatusBadRequest)
			return
		}
		resp["access_token"] = randomString(48)
		resp["refresh_token"] = randomString(48)

	default:
		http.Error(w, "unsupported grant_type", http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/oauth/authorize", authorizeHandler)
	mux.HandleFunc("/oauth/token", tokenHandler)

	fmt.Println("Bitrix24 OAuth2 mock server running")
	fmt.Println("Endpoints:")
	fmt.Println("  - GET /oauth/authorize?client_id=...&redirect_uri=...&state=...")
	fmt.Println("  - POST /oauth/token")

	l, err := net.Listen("tcp", ":0")
	if err != nil {
		fmt.Println("Error starting server:", err)
		return
	}
	fmt.Printf("Server running on http://localhost:%d\n", l.Addr().(*net.TCPAddr).Port)
	http.Serve(l, mux)
}