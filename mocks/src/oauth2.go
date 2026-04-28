package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

var (
	clients = map[string]Client{
		"test-client": {
			ID:     "test-client",
			Secret: "test_secret",
			Name:   "Test Application",
			Scopes: []string{"read", "write", "offline"},
		},
		"app.573ad8a0346747": {
			ID:     "app.573ad8a0346747",
			Secret: "LJSl0lNB76B5YY6u0YVQ3AW0DrVADcRTwVr4y99PXU1BWQybWK",
			Name:   "Bitrix24 Test App",
			Scopes: []string{"crm", "task", "im"},
		},
	}

	authCodes     = make(map[string]AuthorizationCode)
	accessTokens = make(map[string]AccessToken)
	refreshToks  = make(map[string]RefreshToken)

	cfg = &Config{
		Issuer:          "http://localhost:8880",
		AccessTokenTTL:  time.Hour,
		RefreshTokenTTL: 30 * 24 * time.Hour,
		CodeTTL:         10 * time.Minute,
	}
)

type Client struct {
	ID     string
	Secret string
	Name   string
	Scopes []string
}

type AuthorizationCode struct {
	Code        string
	ClientID    string
	RedirectURI string
	Scope       string
	State       string
	ExpiresAt   time.Time
	UserID      string
	CodeChallenge string
	CodeChallengeMethod string
}

type AccessToken struct {
	Token        string
	ClientID     string
	Scope        string
	ExpiresAt    time.Time
	RefreshToken string
	UserID       string
}

type RefreshToken struct {
	Token     string
	ClientID  string
	Scope     string
	ExpiresAt time.Time
	UserID    string
}

type Config struct {
	Issuer           string
	AccessTokenTTL   time.Duration
	RefreshTokenTTL  time.Duration
	CodeTTL          time.Duration
}

func randString(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)[:n]
}

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

func authorizeHandler(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	responseType := q.Get("response_type")
	clientID := q.Get("client_id")
	redirectURI := q.Get("redirect_uri")
	scope := q.Get("scope")
	state := q.Get("state")
	codeChallenge := q.Get("code_challenge")
	codeChallengeMethod := q.Get("code_challenge_method")

	if responseType != "code" {
		errorResponse(w, "unsupported_response_type", "Only 'code' response type is supported")
		return
	}

	client, ok := clients[clientID]
	_ = client
	if !ok {
		errorResponse(w, "invalid_client", "Unknown client_id")
		return
	}

	if redirectURI == "" {
		errorResponse(w, "invalid_request", "redirect_uri is required")
		return
	}

	code := randString(32)
	authCodes[code] = AuthorizationCode{
		Code:                 code,
		ClientID:             clientID,
		RedirectURI:          redirectURI,
		Scope:               scope,
		State:               state,
		ExpiresAt:           time.Now().Add(cfg.CodeTTL),
		UserID:              "user-1",
		CodeChallenge:       codeChallenge,
		CodeChallengeMethod: codeChallengeMethod,
	}

	redirectURL := redirectURI + "?code=" + code
	if state != "" {
		redirectURL += "&state=" + state
	}

	http.Redirect(w, r, redirectURL, http.StatusFound)
}

func tokenHandler(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	grantType := r.Form.Get("grant_type")
	clientID := r.Form.Get("client_id")
	clientSecret := r.Form.Get("client_secret")

	client, ok := clients[clientID]
	if !ok || client.Secret != clientSecret {
		errorResponse(w, "invalid_client", "Invalid client credentials")
		return
	}

	resp := TokenResponse{
		TokenType: "Bearer",
	}

	switch grantType {
	case "authorization_code":
		code := r.Form.Get("code")
		redirectURI := r.Form.Get("redirect_uri")

		if code == "" {
			errorResponse(w, "invalid_request", "code is required")
			return
		}

		authCode, ok := authCodes[code]
		if !ok || time.Now().After(authCode.ExpiresAt) {
			errorResponse(w, "invalid_grant", "Invalid or expired authorization code")
			return
		}

		if authCode.ClientID != clientID || authCode.RedirectURI != redirectURI {
			errorResponse(w, "invalid_grant", "Authorization code does not match client or redirect_uri")
			return
		}

		delete(authCodes, code)

		accessToken := randString(48)
		refreshToken := randString(48)

		accessTokens[accessToken] = AccessToken{
			Token:        accessToken,
			ClientID:     clientID,
			Scope:        authCode.Scope,
			ExpiresAt:    time.Now().Add(cfg.AccessTokenTTL),
			RefreshToken: refreshToken,
			UserID:       authCode.UserID,
		}

		refreshToks[refreshToken] = RefreshToken{
			Token:     refreshToken,
			ClientID:  clientID,
			Scope:     authCode.Scope,
			ExpiresAt: time.Now().Add(cfg.RefreshTokenTTL),
			UserID:    authCode.UserID,
		}

		resp.AccessToken =  accessToken
		resp.RefreshToken = refreshToken
		resp.ExpiresIn =  int(cfg.AccessTokenTTL.Seconds())
		resp.Scope =     authCode.Scope

	case "refresh_token":
		refreshToken := r.Form.Get("refresh_token")
		if refreshToken == "" {
			errorResponse(w, "invalid_request", "refresh_token is required")
			return
		}

		rt, ok := refreshToks[refreshToken]
		if !ok || time.Now().After(rt.ExpiresAt) {
			errorResponse(w, "invalid_grant", "Invalid or expired refresh token")
			return
		}

		delete(refreshToks, refreshToken)

		newAccessToken := randString(48)
		newRefreshToken := randString(48)

		accessTokens[newAccessToken] = AccessToken{
			Token:        newAccessToken,
			ClientID:     rt.ClientID,
			Scope:        rt.Scope,
			ExpiresAt:    time.Now().Add(cfg.AccessTokenTTL),
			RefreshToken: newRefreshToken,
			UserID:       rt.UserID,
		}

		refreshToks[newRefreshToken] = RefreshToken{
			Token:     newRefreshToken,
			ClientID:  rt.ClientID,
			Scope:     rt.Scope,
			ExpiresAt: time.Now().Add(cfg.RefreshTokenTTL),
			UserID:    rt.UserID,
		}

		resp.AccessToken =  newAccessToken
		resp.RefreshToken = newRefreshToken
		resp.ExpiresIn =  int(cfg.AccessTokenTTL.Seconds())
		resp.Scope =     rt.Scope

	default:
		errorResponse(w, "unsupported_grant_type", "Unsupported grant_type. Use 'authorization_code' or 'refresh_token'")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func userinfoHandler(w http.ResponseWriter, r *http.Request) {
	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, "Bearer ") {
		errorResponse(w, "invalid_token", "Missing or invalid authorization header")
		return
	}

	token := strings.TrimPrefix(authHeader, "Bearer ")
	at, ok := accessTokens[token]
	if !ok || time.Now().After(at.ExpiresAt) {
		errorResponse(w, "invalid_token", "Invalid or expired access token")
		return
	}

	resp := map[string]interface{}{
		"sub":   at.UserID,
		"scope": at.Scope,
		"iss":   cfg.Issuer,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func jwksHandler(w http.ResponseWriter, r *http.Request) {
	resp := map[string]interface{}{
		"keys": []map[string]string{},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func errorResponse(w http.ResponseWriter, error, description string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	json.NewEncoder(w).Encode(map[string]string{
		"error":             error,
		"error_description": description,
	})
}

type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token,omitempty"`
	Scope       string `json:"scope,omitempty"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/authorize", authorizeHandler)
	mux.HandleFunc("/token", tokenHandler)
	mux.HandleFunc("/userinfo", userinfoHandler)
	mux.HandleFunc("/.well-known/jwks.json", jwksHandler)

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("OK"))
	})

	fmt.Println("OAuth2 Mock Server running on http://localhost:8880")
	fmt.Println("Endpoints:")
	fmt.Println("  GET  /authorize  - Authorization endpoint")
	fmt.Println("  POST /token      - Token endpoint")
	fmt.Println("  GET  /userinfo   - Userinfo endpoint")
	fmt.Println("  GET  /.well-known/jwks.json - JWKS endpoint")
	fmt.Println("")
	fmt.Println("Test credentials:")
	fmt.Println("  client_id:     test-client")
	fmt.Println("  client_secret: test_secret")
	fmt.Println("")
	fmt.Println("Authorization URL:")
	fmt.Println("  /authorize?response_type=code&client_id=test-client&redirect_uri=http://localhost:3000/callback&scope=read write")

	http.ListenAndServe(":8880", mux)
}