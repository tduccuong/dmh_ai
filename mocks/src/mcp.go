package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

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

type InitializeParams struct {
	ProtocolVersion string `json:"protocolVersion"`
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

type ToolsCapability struct {
	ListChanged bool `json:"listChanged"`
}

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

type ListDirArgs struct {
	Path string `json:"path"`
}

type ReadFileArgs struct {
	Path string `json:"path"`
}

func main() {
	logger := log.New(os.Stderr, "mcp: ", log.LstdFlags)
	logger.Println("MCP server started")

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}

		logger.Printf("received: %s", line)

		var req JSONRPCRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			sendError(nil, -32700, "Parse error")
			continue
		}

		handleRequest(req, logger)
	}

	if err := scanner.Err(); err != nil {
		logger.Printf("scanner error: %v", err)
	}
}

func handleRequest(req JSONRPCRequest, logger *log.Logger) {
	switch req.Method {
	case "initialize":
		sendInitializeResult(req.ID)
	case "tools/list":
		sendToolsList(req.ID)
	case "tools/call":
		handleToolCall(req, logger)
	case "notifications/initialized":
	default:
		sendError(req.ID, -32601, "Method not found")
	}
}

func sendInitializeResult(id interface{}) {
	result := InitializeResult{
		ProtocolVersion: "2024-11-05",
		ServerInfo: ServerInfo{
			Name:    "mcp-mock-server",
			Version: "1.0.0",
		},
		Capabilities: Capabilities{
			Tools: ToolsCapability{ListChanged: false},
		},
	}
	sendResponse(id, result)
}

func sendToolsList(id interface{}) {
	tools := ListToolsResult{
		Tools: []Tool{
			{
				Name:        "list_dir",
				Description: "List contents of a directory",
				InputSchema: InputSchema{
					Type: "object",
					Properties: map[string]Property{
						"path": {
							Type:        "string",
							Description: "Path to the directory to list",
						},
					},
					Required: []string{"path"},
				},
			},
			{
				Name:        "read_file",
				Description: "Read contents of a file",
				InputSchema: InputSchema{
					Type: "object",
					Properties: map[string]Property{
						"path": {
							Type:        "string",
							Description: "Path to the file to read",
						},
					},
					Required: []string{"path"},
				},
			},
		},
	}
	sendResponse(id, tools)
}

func handleToolCall(req JSONRPCRequest, logger *log.Logger) {
	var params CallToolParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		sendError(req.ID, -32602, "Invalid params")
		return
	}

	switch params.Name {
	case "list_dir":
		handleListDir(req.ID, params.Arguments, logger)
	case "read_file":
		handleReadFile(req.ID, params.Arguments, logger)
	default:
		sendError(req.ID, -32602, "Unknown tool: "+params.Name)
	}
}

func handleListDir(id interface{}, argsJSON json.RawMessage, logger *log.Logger) {
	var args ListDirArgs
	if err := json.Unmarshal(argsJSON, &args); err != nil {
		sendError(id, -32602, "Invalid arguments")
		return
	}

	entries, err := os.ReadDir(args.Path)
	if err != nil {
		sendError(id, -32603, fmt.Sprintf("Failed to read directory: %v", err))
		return
	}

	result := CallToolResult{
		Content: []Content{
			{Type: "text", Text: fmt.Sprintf("Contents of %s:\n", args.Path)},
		},
	}

	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			result.Content = append(result.Content, Content{
				Type: "text",
				Text: fmt.Sprintf("  %s (unable to get info)\n", entry.Name()),
			})
			continue
		}

		mode := info.Mode()
		var typeStr string
		if mode.IsDir() {
			typeStr = "DIR"
		} else if mode.IsRegular() {
			typeStr = "FILE"
		} else {
			typeStr = "OTHER"
		}

		result.Content = append(result.Content, Content{
			Type: "text",
			Text: fmt.Sprintf("  [%s] %s (%d bytes)\n", typeStr, entry.Name(), info.Size()),
		})
	}

	sendResponse(id, result)
}

func handleReadFile(id interface{}, argsJSON json.RawMessage, logger *log.Logger) {
	var args ReadFileArgs
	if err := json.Unmarshal(argsJSON, &args); err != nil {
		sendError(id, -32602, "Invalid arguments")
		return
	}

	absPath, err := filepath.Abs(args.Path)
	if err != nil {
		sendError(id, -32603, fmt.Sprintf("Failed to resolve path: %v", err))
		return
	}

	content, err := os.ReadFile(absPath)
	if err != nil {
		sendError(id, -32603, fmt.Sprintf("Failed to read file: %v", err))
		return
	}

	result := CallToolResult{
		Content: []Content{
			{Type: "text", Text: string(content)},
		},
	}

	sendResponse(id, result)
}

func sendResponse(id interface{}, result interface{}) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}
	writeResponse(resp)
}

func sendError(id interface{}, code int, message string) {
	resp := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: &RPCError{
			Code:    code,
			Message: message,
		},
	}
	writeResponse(resp)
}

func writeResponse(resp JSONRPCResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	fmt.Println(string(data))
}
