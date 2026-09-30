package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSQLiteAPIParameters(t *testing.T) {
	endpoints := []struct {
		name    string
		path    string
		command string
		sql     string
		handler func(*DebugServer, http.ResponseWriter, *http.Request)
	}{
		{"查询", "/api/sqlite/query", "query_sqlite", "SELECT 1", (*DebugServer).handleAPISQLiteQuery},
		{"写入", "/api/sqlite/mutate", "mutate_sqlite", "UPDATE sample SET title = ? WHERE id = ?", (*DebugServer).handleAPISQLiteMutate},
	}
	cases := []struct {
		name       string
		field      string
		wantJSON   string
		wantStatus int
	}{
		{"缺失", "", "[]", http.StatusOK},
		{"空值", `,"parameters":null`, "[]", http.StatusOK},
		{"空数组", `,"parameters":[]`, "[]", http.StatusOK},
		{"保留参数类型与顺序", `,"parameters":["中文",7,2.5,true,false,null]`, `["中文",7,2.5,true,false,null]`, http.StatusOK},
		{"字符串", `,"parameters":"[]"`, "", http.StatusBadRequest},
		{"数字", `,"parameters":1`, "", http.StatusBadRequest},
		{"布尔值", `,"parameters":true`, "", http.StatusBadRequest},
		{"对象", `,"parameters":{}`, "", http.StatusBadRequest},
	}

	for _, endpoint := range endpoints {
		for _, tc := range cases {
			t.Run(endpoint.name+"/"+tc.name, func(t *testing.T) {
				server := NewDebugServer("127.0.0.1", 7654)
				body := `{"database":"chat","sql":"` + endpoint.sql + `"` + tc.field + `}`
				req := httptest.NewRequest(http.MethodPost, endpoint.path, strings.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				recorder := httptest.NewRecorder()

				if tc.wantStatus == http.StatusOK {
					go resolveNextPendingResponse(server, map[string]any{"status": "ok"})
				}
				endpoint.handler(server, recorder, req)
				if recorder.Code != tc.wantStatus {
					t.Fatalf("状态码 = %d，期望 %d；响应：%s", recorder.Code, tc.wantStatus, recorder.Body.String())
				}
				response := decodeJSONBody(t, recorder)
				server.mu.RLock()
				defer server.mu.RUnlock()
				if tc.wantStatus == http.StatusBadRequest {
					if response["status"] != "error" || response["error_code"] != "INVALID_ARGS" {
						t.Fatalf("期望参数错误，实际响应：%v", response)
					}
					if len(server.commandQueue) != 0 || len(server.pendingResponses) != 0 {
						t.Fatal("无效参数不应进入设备命令队列或注册待响应请求")
					}
					return
				}

				if response["status"] != "ok" || len(server.commandQueue) != 1 {
					t.Fatalf("期望成功转发一个命令，响应：%v，队列长度：%d", response, len(server.commandQueue))
				}
				command := server.commandQueue[0]
				if command["command"] != endpoint.command || command["database"] != "chat" || command["sql"] != endpoint.sql {
					t.Fatalf("转发的命令不匹配：%v", command)
				}
				// 检查发送到设备的 JSON，防止 nil 切片再次被编码成 null。
				encoded, err := json.Marshal(command)
				if err != nil {
					t.Fatalf("命令编码失败：%v", err)
				}
				var wireCommand map[string]json.RawMessage
				if err := json.Unmarshal(encoded, &wireCommand); err != nil {
					t.Fatalf("命令解码失败：%v", err)
				}
				if got := string(wireCommand["parameters"]); got != tc.wantJSON {
					t.Fatalf("发送的 parameters = %s，期望 %s", got, tc.wantJSON)
				}
			})
		}
	}
}
