package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

const validAPIKey = "test-api-key-12345"

type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type JSONRPCResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Result  interface{} `json:"result,omitempty"`
	Error   *RPCError  `json:"error,omitempty"`
}

type RPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

type InitializeResult struct {
	ProtocolVersion string       `json:"protocolVersion"`
	ServerInfo      ServerInfo  `json:"serverInfo"`
	Capabilities    Capabilities `json:"capabilities"`
}

type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type Capabilities struct {
	Tools ToolsCapability `json:"tools"`
}

type ToolsCapability struct{}

type ListToolsResult struct {
	Tools []Tool `json:"tools"`
}

type Tool struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	InputSchema InputSchema `json:"inputSchema"`
}

type InputSchema struct {
	Type       string              `json:"type"`
	Properties map[string]Property `json:"properties"`
	Required   []string            `json:"required"`
}

type Property struct {
	Type        string `json:"type"`
	Description string `json:"description"`
}

type CallToolParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

type CallToolResult struct {
	Content []Content `json:"content"`
}

type Content struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func main() {
	port := flag.Int("port", 9091, "Port to listen on")
	flag.Parse()

	http.HandleFunc("/mcp", mcpHandler)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("MCP api_key mock running on http://localhost:%d/mcp", *port)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func mcpHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	apiKey := extractAPIKey(r)
	if apiKey != validAPIKey {
		w.Header().Set("WWW-Authenticate", `Bearer realm="mcp_api_key"`)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      nil,
			Error: &RPCError{
				Code:    -32001,
				Message: "Authentication required",
			},
		}
		json.NewEncoder(w).Encode(resp)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	var req JSONRPCRequest
	if err := json.Unmarshal(body, &req); err != nil {
		sendError(w, nil, -32700, "Parse error")
		return
	}

	handleRequest(w, req)
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

func handleRequest(w http.ResponseWriter, req JSONRPCRequest) {
	switch req.Method {
	case "initialize":
		sendInitializeResult(w, req.ID)
	case "tools/list":
		sendToolsList(w, req.ID)
	case "tools/call":
		handleToolCall(w, req)
	default:
		sendError(w, req.ID, -32601, "Method not found")
	}
}

func sendInitializeResult(w http.ResponseWriter, id interface{}) {
	result := InitializeResult{
		ProtocolVersion: "2024-11-05",
		ServerInfo: ServerInfo{
			Name:    "mcp_api_key_mock",
			Version: "0.1.0",
		},
		Capabilities: Capabilities{
			Tools: ToolsCapability{},
		},
	}
	sendResponse(w, id, result)
}

func sendToolsList(w http.ResponseWriter, id interface{}) {
	tools := ListToolsResult{
		Tools: []Tool{
			{
				Name:        "echo",
				Description: "Echo a message back.",
				InputSchema: InputSchema{
					Type: "object",
					Properties: map[string]Property{
						"message": {
							Type:        "string",
							Description: "Message to echo",
						},
					},
					Required: []string{"message"},
				},
			},
			{
				Name:        "current_time",
				Description: "Return current UTC time as RFC3339.",
				InputSchema: InputSchema{
					Type:       "object",
					Properties: map[string]Property{},
					Required:   []string{},
				},
			},
		},
	}
	sendResponse(w, id, tools)
}

func handleToolCall(w http.ResponseWriter, req JSONRPCRequest) {
	var params CallToolParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		sendError(w, req.ID, -32602, "Invalid params")
		return
	}

	switch params.Name {
	case "echo":
		handleEcho(w, req.ID, params.Arguments)
	case "current_time":
		handleCurrentTime(w, req.ID)
	default:
		sendError(w, req.ID, -32601, "Method not found")
	}
}

func handleEcho(w http.ResponseWriter, id interface{}, argsJSON json.RawMessage) {
	var args struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(argsJSON, &args); err != nil {
		sendError(w, id, -32602, "Invalid arguments")
		return
	}

	result := CallToolResult{
		Content: []Content{
			{Type: "text", Text: "echo: " + args.Message},
		},
	}
	sendResponse(w, id, result)
}

func handleCurrentTime(w http.ResponseWriter, id interface{}) {
	now := time.Now().UTC().Format(time.RFC3339)
	result := CallToolResult{
		Content: []Content{
			{Type: "text", Text: now},
		},
	}
	sendResponse(w, id, result)
}

func sendResponse(w http.ResponseWriter, id interface{}, result interface{}) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func sendError(w http.ResponseWriter, id interface{}, code int, message string) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: &RPCError{
			Code:    code,
			Message: message,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
