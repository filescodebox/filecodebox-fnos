// Package trimapi 是飞牛官方后端开放 API 的统一 client。
//
// 官方契约(developer.fnnas.com/api/calling「调用方式」):
//
//	POST /api/v1/trimapp  (经 Unix Socket /var/run/trim_open_gateway_apiscope.socket)
//	Authorization: Bearer <TRIM_API_TOKEN>
//	{"reqId":"...","req":"trim.file.xxx","appName":"...","data":{...}}
//	→ {"reqId":"...","code":0,"msg":"","data":{...}}
//
// 安全边界:token 由框架在拉起应用脚本时注入 TRIM_API_TOKEN,官方明确要求
// 每次调用时从进程环境现读——不持久化、不缓存、不下发前端。本 client 严格遵循。
package trimapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

// Client 官方后端开放 API client。
type Client struct {
	socketPath string
	appName    string
	http       *http.Client
}

// New 创建 client。socketPath=官方 API socket,appName=应用名。
func New(socketPath, appName string) *Client {
	return &Client{
		socketPath: socketPath,
		appName:    appName,
		http: &http.Client{
			Timeout: 5 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", socketPath)
				},
			},
		},
	}
}

// envelope 官方请求/响应公共壳。
type envelope struct {
	ReqID   string          `json:"reqId"`
	Req     string          `json:"req"`
	AppName string          `json:"appName"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type respEnvelope struct {
	ReqID string          `json:"reqId"`
	Code  int             `json:"code"`
	Msg   string          `json:"msg"`
	Data  json.RawMessage `json:"data"`
}

// Call 统一请求入口:req=能力标识(如 trim.file.getSharedAccessibleFolders),
// data=接口参数,result=成功响应的 data 反序列化目标(可为 nil)。
// 官方语义:code==0 成功;HTTP 403=scope 未声明;404=req 不存在或系统版本不支持。
func (c *Client) Call(ctx context.Context, req string, data any, result any) error {
	var payload []byte
	if data != nil {
		b, err := json.Marshal(data)
		if err != nil {
			return fmt.Errorf("trimapi %s: 序列化参数失败: %w", req, err)
		}
		payload = b
	} else {
		payload = []byte("{}")
	}
	body, err := json.Marshal(envelope{
		ReqID:   fmt.Sprintf("%d", time.Now().UnixNano()),
		Req:     req,
		AppName: c.appName,
		Data:    payload,
	})
	if err != nil {
		return fmt.Errorf("trimapi %s: 构造请求失败: %w", req, err)
	}

	token := os.Getenv("TRIM_API_TOKEN")
	if token == "" {
		return fmt.Errorf("trimapi %s: TRIM_API_TOKEN 未注入(非 fnOS 管理态运行?)", req)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"http://localhost/api/v1/trimapp", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("trimapi %s: 构造请求失败: %w", req, err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+token)

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return fmt.Errorf("trimapi %s: 请求失败: %w", req, err)
	}
	defer resp.Body.Close()

	var env respEnvelope
	decoder := json.NewDecoder(resp.Body)
	if err := decoder.Decode(&env); err != nil {
		return fmt.Errorf("trimapi %s: HTTP %d,响应解析失败: %w", req, resp.StatusCode, err)
	}
	if resp.StatusCode != http.StatusOK || env.Code != 0 {
		return &APIError{Req: req, HTTPStatus: resp.StatusCode, Code: env.Code, Msg: env.Msg}
	}
	if result != nil && len(env.Data) > 0 {
		if err := json.Unmarshal(env.Data, result); err != nil {
			return fmt.Errorf("trimapi %s: 响应 data 解析失败: %w", req, err)
		}
	}
	return nil
}

// APIError 官方 API 业务错误(HTTP 状态码 + code + msg)。
type APIError struct {
	Req        string
	HTTPStatus int
	Code       int
	Msg        string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("trimapi %s: HTTP %d code=%d msg=%q", e.Req, e.HTTPStatus, e.Code, e.Msg)
}

// ---- 各能力封装(字段契约见 developer.fnnas.com/api 对应页) ----

// SharedFolders 应用共享授权目录查询(trim.file.getSharedAccessibleFolders)。
func (c *Client) SharedFolders(ctx context.Context) ([]string, error) {
	var out struct {
		Paths []string `json:"paths"`
	}
	if err := c.Call(ctx, "trim.file.getSharedAccessibleFolders", map[string]any{}, &out); err != nil {
		return nil, err
	}
	return out.Paths, nil
}

// UserFolders 指定用户授权目录查询(trim.file.getUserAccessibleFolders)。
func (c *Client) UserFolders(ctx context.Context, uid int64) ([]string, error) {
	var out struct {
		Paths []string `json:"paths"`
	}
	if err := c.Call(ctx, "trim.file.getUserAccessibleFolders", map[string]any{"uid": uid}, &out); err != nil {
		return nil, err
	}
	return out.Paths, nil
}

// CheckUserACL 用户路径权限检查(trim.file.checkUserACL)。
// 返回与请求路径顺序对应的权限结果;路径不存在时官方返回全 false,不视为错误。
type ACLResult struct {
	Path      string `json:"path"`
	Readable  bool   `json:"readable"`
	Writable  bool   `json:"writable"`
	Deletable bool   `json:"deletable"`
}

func (c *Client) CheckUserACL(ctx context.Context, uid int64, paths []string) ([]ACLResult, error) {
	var out []ACLResult
	if err := c.Call(ctx, "trim.file.checkUserACL", map[string]any{"uid": uid, "path": paths}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ConvertPaths 内部路径→用户可读展示路径(trim.file.convertPath)。
// language 必传(官方要求,按当前界面语言)。
type ConvertedPath struct {
	Path         string `json:"path"`
	SemanticPath string `json:"semanticPath"`
}

func (c *Client) ConvertPaths(ctx context.Context, language string, paths []string) ([]ConvertedPath, error) {
	var out struct {
		Status int             `json:"status"`
		Result []ConvertedPath `json:"result"`
	}
	if err := c.Call(ctx, "trim.file.convertPath", map[string]any{"path": paths, "language": language}, &out); err != nil {
		return nil, err
	}
	return out.Result, nil
}

// PlatformConfig 系统语言/版本(trim.system.getPlatformConfig)。
type PlatformConfig struct {
	SystemLanguage string `json:"systemLanguage"`
	SystemVersion  string `json:"systemVersion"`
}

func (c *Client) PlatformConfig(ctx context.Context) (*PlatformConfig, error) {
	var out PlatformConfig
	if err := c.Call(ctx, "trim.system.getPlatformConfig", map[string]any{}, &out); err != nil {
		return nil, err
	}
	return &out, nil
}
