package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"time"
)

const validAPIKey = "test-api-key-12345"

var (
	clientSecrets = map[string]string{
		"app.test123": "test_secret_123",
	}
	authCodes = make(map[string]time.Time)
	baseURL   string
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

func protectedResourceHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"resource":             baseURL,
		"authorization_servers": []string{baseURL},
	})
}

func authorizationServerHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"issuer":                          baseURL,
		"authorization_endpoint":           baseURL + "/oauth/authorize",
		"token_endpoint":                   baseURL + "/oauth/token",
		"grant_types_supported":            []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported": []string{"S256"},
	})
}

func mcpHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	apiKey := extractAPIKey(r)
	if apiKey != validAPIKey {
		w.Header().Set("WWW-Authenticate", `Bearer realm="mcp_api_key"`)
		w.WriteHeader(http.StatusUnauthorized)
		resp := map[string]interface{}{
			"jsonrpc": "2.0",
			"error": map[string]interface{}{
				"code":    -32001,
				"message": "Authentication required",
			},
			"id": nil,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	var req map[string]interface{}
	if err := json.Unmarshal(body, &req); err != nil {
		sendMCPError(w, nil, -32700, "Parse error")
		return
	}

	method, _ := req["method"].(string)
	id := req["id"]

	switch method {
	case "initialize":
		sendMCPResponse(w, id, map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"serverInfo": map[string]interface{}{
				"name":    "bitrix24_mcp_mock",
				"version": "0.1.0",
			},
			"capabilities": map[string]interface{}{
				"tools": map[string]interface{}{},
			},
		})
	case "tools/list":
		sendMCPResponse(w, id, map[string]interface{}{
			"tools": []map[string]interface{}{
				{
					"name":        "echo",
					"description": "Echo a message back.",
					"inputSchema": map[string]interface{}{
						"type": "object",
						"properties": map[string]interface{}{
							"message": map[string]interface{}{
								"type":        "string",
								"description": "Message to echo",
							},
						},
						"required": []string{"message"},
					},
				},
				{
					"name":        "current_time",
					"description": "Return current UTC time as RFC3339.",
					"inputSchema": map[string]interface{}{
						"type":       "object",
						"properties": map[string]interface{}{},
						"required":   []string{},
					},
				},
			},
		})
	case "tools/call":
		args, _ := req["params"].(map[string]interface{})
		toolName, _ := args["name"].(string)
		toolArgs, _ := args["arguments"].(map[string]interface{})
		switch toolName {
		case "echo":
			message, _ := toolArgs["message"].(string)
			sendMCPResponse(w, id, map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "echo: " + message},
				},
			})
		case "current_time":
			sendMCPResponse(w, id, map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": time.Now().UTC().Format(time.RFC3339)},
				},
			})
		default:
			sendMCPError(w, id, -32601, "Method not found")
		}
	default:
		sendMCPError(w, id, -32601, "Method not found")
	}
}

func extractAPIKey(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}
	const prefix = "Bearer "
	if len(auth) < len(prefix) || auth[:len(prefix)] != prefix {
		return ""
	}
	return auth[len(prefix):]
}

func sendMCPResponse(w http.ResponseWriter, id interface{}, result interface{}) {
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func sendMCPError(w http.ResponseWriter, id interface{}, code int, message string) {
	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]interface{}{
			"code":    code,
			"message": message,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/oauth/authorize", authorizeHandler)
	mux.HandleFunc("/oauth/token", tokenHandler)
	// RFC 8615 inserts `.well-known/<suffix>` between authority and
	// path. So a runtime probing an MCP at `<base>/mcp` fetches PRM
	// at `<base>/.well-known/oauth-protected-resource/mcp`. Register
	// both the bare and `/mcp`-suffixed forms so the discovery
	// cascade lands the docs regardless of which the runtime tries.
	mux.HandleFunc("/.well-known/oauth-protected-resource", protectedResourceHandler)
	mux.HandleFunc("/.well-known/oauth-protected-resource/mcp", protectedResourceHandler)
	mux.HandleFunc("/.well-known/oauth-authorization-server", authorizationServerHandler)
	mux.HandleFunc("/.well-known/oauth-authorization-server/mcp", authorizationServerHandler)
	mux.HandleFunc("/mcp", mcpHandler)

	fmt.Println("Bitrix24 OAuth2 mock server running")
	fmt.Println("Endpoints:")
	fmt.Println("  - GET /oauth/authorize?client_id=...&redirect_uri=...&state=...")
	fmt.Println("  - POST /oauth/token")
	fmt.Println("  - GET /.well-known/oauth-protected-resource")
	fmt.Println("  - GET /.well-known/oauth-authorization-server")
	fmt.Println("  - POST /mcp (requires Bearer auth)")

	l, err := net.Listen("tcp", ":0")
	if err != nil {
		fmt.Println("Error starting server:", err)
		return
	}
	port := l.Addr().(*net.TCPAddr).Port
	baseURL = fmt.Sprintf("http://localhost:%d", port)
	fmt.Printf("Server running on %s\n", baseURL)
	http.Serve(l, mux)
}