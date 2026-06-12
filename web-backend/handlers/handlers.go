package handlers

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"sb-manager-web/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

// ============================================================================
// 工具函数
// ============================================================================

func formatBytes(bytes int64) string {
	if bytes >= 1099511627776 {
		return fmt.Sprintf("%.2f TB", float64(bytes)/1099511627776)
	} else if bytes >= 1073741824 {
		return fmt.Sprintf("%.2f GB", float64(bytes)/1073741824)
	} else if bytes >= 1048576 {
		return fmt.Sprintf("%.2f MB", float64(bytes)/1048576)
	} else if bytes >= 1024 {
		return fmt.Sprintf("%.2f KB", float64(bytes)/1024)
	}
	return fmt.Sprintf("%d B", bytes)
}

func formatTimestamp(ts int64) string {
	if ts == 0 {
		return "N/A"
	}
	return time.Unix(ts, 0).Format("2006-01-02 15:04:05")
}

func protocolLabel(p string) string {
	switch p {
	case "vless-reality":
		return "VLESS + Reality"
	case "hysteria2":
		return "Hysteria2"
	case "tuic":
		return "TUIC v5"
	case "anytls":
		return "AnyTLS"
	case "shadowtls":
		return "ShadowTLS v3"
	default:
		return p
	}
}

func loadJSONFile(path string, v interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func saveJSONFile(path string, v interface{}) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func runShell(script string, args ...string) (string, error) {
	cmdArgs := append([]string{script}, args...)
	cmd := exec.Command("bash", cmdArgs...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}

// ============================================================================
// Settings
// ============================================================================

type Settings = models.Settings

func LoadSettings(path string) (*Settings, error) {
	s := &Settings{}
	if err := loadJSONFile(path, s); err != nil {
		if os.IsNotExist(err) {
			return &Settings{
				WebPort:     "2053",
				WebUsername: "admin",
				JWTSecret:   "default-secret-change-me",
			}, nil
		}
		return nil, err
	}
	return s, nil
}

// ============================================================================
// Auth Handler
// ============================================================================

func Login(settings *Settings) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req struct {
			Username string `json:"username" form:"username"`
			Password string `json:"password" form:"password"`
		}
		if err := c.ShouldBind(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效请求"})
			return
		}

		// 验证密码
		hash := settings.WebPasswordHash
		if hash == "" {
			// 默认密码: admin
			hash = "$2a$10$default-hash-not-set"
		}

		if req.Username != settings.WebUsername {
			time.Sleep(1 * time.Second) // 防止暴力破解
			c.JSON(http.StatusUnauthorized, gin.H{"error": "用户名或密码错误"})
			return
		}

		if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)); err != nil {
			// 如果 hash 无效, 允许明文 "admin" (首次安装)
			if req.Password != "admin" || hash == "" {
				log.Printf("login failed from %s", c.ClientIP())
				time.Sleep(1 * time.Second)
				c.JSON(http.StatusUnauthorized, gin.H{"error": "用户名或密码错误"})
				return
			}
		}

		// 生成 JWT
		token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
			"username": req.Username,
			"exp":      time.Now().Add(24 * time.Hour).Unix(),
		})
		tokenStr, _ := token.SignedString([]byte(settings.JWTSecret))

		// 设置 cookie
		c.SetCookie("sb_token", tokenStr, 86400, "/", "", false, true)

		// HTMX 请求重定向到首页
		if c.GetHeader("HX-Request") == "true" {
			c.Header("HX-Redirect", "/dashboard")
			c.Status(http.StatusOK)
			return
		}

		c.JSON(http.StatusOK, gin.H{
			"token":    tokenStr,
			"redirect": "/dashboard",
		})
	}
}

// ============================================================================
// Dashboard
// ============================================================================

func GetDashboard(usersFile, outboundsFile, trafficFile string) gin.H {
	totalUsers := 0
	activeUsers := 0
	onlineUsers := 0
	totalDown := int64(0)
	totalUp := int64(0)

	uf := &models.UsersFile{}
	if err := loadJSONFile(usersFile, uf); err == nil {
		totalUsers = len(uf.Users)
		for _, u := range uf.Users {
			if u.Status == "active" {
				activeUsers++
			}
			if u.Online {
				onlineUsers++
			}
		}
	}

	tf := &models.TrafficFile{}
	if err := loadJSONFile(trafficFile, tf); err == nil {
		totalDown = tf.Total.Down
		totalUp = tf.Total.Up
	}

	outboundCount := 0
	of := &models.OutboundsFile{}
	if err := loadJSONFile(outboundsFile, of); err == nil {
		outboundCount = len(of.Outbounds)
	}

	return gin.H{
		"title":         "仪表盘 - Sing-box Manager",
		"totalUsers":    totalUsers,
		"activeUsers":   activeUsers,
		"onlineUsers":   onlineUsers,
		"outboundCount": outboundCount,
		"totalDown":     formatBytes(totalDown),
		"totalUp":       formatBytes(totalUp),
	}
}

func APIDashboard(usersFile, outboundsFile, trafficFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.JSON(http.StatusOK, GetDashboard(usersFile, outboundsFile, trafficFile))
	}
}

// ============================================================================
// Users Page
// ============================================================================

func GetUsersPage(usersFile string) gin.H {
	uf := &models.UsersFile{}
	loadJSONFile(usersFile, uf)

	type UserRow struct {
		Username  string
		Protocol  string
		Port      int
		Status    string
		StatusBadge template.HTML
		ExpireAt  string
		Used      string
		Limit     string
		Online    string
	}

	var rows []UserRow
	for _, u := range uf.Users {
		used := u.TrafficUsedDown + u.TrafficUsedUp
		statusBadge := `<span class="badge bg-danger">禁用</span>`
		if u.Status == "active" {
			statusBadge = `<span class="badge bg-success">启用</span>`
		}
		online := `<span class="text-muted">离线</span>`
		if u.Online {
			online = `<span class="text-success">在线</span>`
		}
		rows = append(rows, UserRow{
			Username:    u.Username,
			Protocol:    protocolLabel(u.Protocol),
			Port:        u.Inbound.Port,
			Status:      u.Status,
			StatusBadge: statusBadge,
			ExpireAt:    formatTimestamp(u.ExpireAt),
			Used:        formatBytes(used),
			Limit:       formatBytes(u.TrafficLimitBytes),
			Online:      online,
		})
	}

	return gin.H{
		"title": "用户管理 - Sing-box Manager",
		"users": rows,
	}
}

func APIListUsers(usersFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		uf := &models.UsersFile{}
		if err := loadJSONFile(usersFile, uf); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		type UserResp struct {
			Username      string `json:"username"`
			Protocol      string `json:"protocol"`
			Status        string `json:"status"`
			Port          int    `json:"port"`
			ExpireAt      int64  `json:"expire_at"`
			TrafficUsed   int64  `json:"traffic_used"`
			TrafficLimit  int64  `json:"traffic_limit"`
			Online        bool   `json:"online"`
			SubURL        string `json:"subscription_url"`
		}

		var users []UserResp
		for _, u := range uf.Users {
			users = append(users, UserResp{
				Username:     u.Username,
				Protocol:     u.Protocol,
				Status:       u.Status,
				Port:         u.Inbound.Port,
				ExpireAt:     u.ExpireAt,
				TrafficUsed:  u.TrafficUsedDown + u.TrafficUsedUp,
				TrafficLimit: u.TrafficLimitBytes,
				Online:       u.Online,
				SubURL:       u.Subscription.URL,
			})
		}
		c.JSON(http.StatusOK, gin.H{"users": users, "total": len(users)})
	}
}

func APIAddUser(usersFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req struct {
			Username     string `json:"username" form:"username"`
			Protocol     string `json:"protocol" form:"protocol"`
			ExpireDays   int    `json:"expire_days" form:"expire_days"`
			TrafficLimit string `json:"traffic_limit" form:"traffic_limit"`
			Port         int    `json:"port" form:"port"`
		}
		if err := c.ShouldBind(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效参数"})
			return
		}

		if req.Username == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "用户名不能为空"})
			return
		}
		if req.ExpireDays <= 0 {
			req.ExpireDays = 30
		}
		if req.TrafficLimit == "" {
			req.TrafficLimit = "100GB"
		}

		// 调用 manager.sh add-user
		script := scriptsDir + "/manager.sh"
		args := []string{
			"add-user",
			req.Username,
			req.Protocol,
			fmt.Sprintf("%d", req.ExpireDays),
			req.TrafficLimit,
		}
		if req.Port > 0 {
			args = append(args, fmt.Sprintf("%d", req.Port))
		}

		output, err := runShell(script, args...)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "添加用户失败: " + output})
			return
		}

		// 返回更新后的用户列表 HTML
		c.JSON(http.StatusOK, gin.H{"message": "用户添加成功", "output": output})
	}
}

func APIDeleteUser(usersFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		username := c.Param("username")
		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "delete-user", username)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败: " + output})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "用户已删除"})
	}
}

func APIEditUser(usersFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		username := c.Param("username")
		var req struct {
			ExpireDays   int    `json:"expire_days" form:"expire_days"`
			TrafficLimit string `json:"traffic_limit" form:"traffic_limit"`
			Status       string `json:"status" form:"status"`
		}
		if err := c.ShouldBind(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效参数"})
			return
		}

		script := scriptsDir + "/manager.sh"
		if req.ExpireDays > 0 {
			runShell(script, "edit-user", username, "1", fmt.Sprintf("%d", req.ExpireDays))
		}
		if req.TrafficLimit != "" {
			runShell(script, "edit-user", username, "2", req.TrafficLimit)
		}
		if req.Status != "" {
			runShell(script, "edit-user", username, "4", req.Status)
		}

		c.JSON(http.StatusOK, gin.H{"message": "修改成功"})
	}
}

func APIGetUserConfig(usersFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		username := c.Param("username")
		format := c.DefaultQuery("format", "all")

		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "show-config", username, format)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": output})
			return
		}

		// 解析 share link
		lines := strings.Split(strings.TrimSpace(output), "\n")
		var shareLink string
		for _, line := range lines {
			if strings.HasPrefix(line, "vless://") ||
				strings.HasPrefix(line, "hysteria2://") ||
				strings.HasPrefix(line, "tuic://") ||
				strings.HasPrefix(line, "anytls://") ||
				strings.HasPrefix(line, "shadowtls://") {
				shareLink = line
				break
			}
		}

		c.JSON(http.StatusOK, gin.H{
			"share_link": shareLink,
			"raw":        output,
		})
	}
}

// ============================================================================
// Outbounds
// ============================================================================

func GetOutboundsPage(outboundsFile string) gin.H {
	of := &models.OutboundsFile{}
	loadJSONFile(outboundsFile, of)

	type OutRow struct {
		ID        string
		Name      string
		Type      string
		Tag       string
		CreatedAt string
		Builtin   bool
	}

	var rows []OutRow
	for _, o := range of.Outbounds {
		rows = append(rows, OutRow{
			ID:        o.ID,
			Name:      o.Name,
			Type:      o.Type,
			Tag:       o.Tag,
			CreatedAt: formatTimestamp(o.CreatedAt),
			Builtin:   o.Builtin,
		})
	}

	return gin.H{
		"title":          "出站管理 - Sing-box Manager",
		"outbounds":      rows,
		"strategyGroups": of.StrategyGroups,
	}
}

func APIListOutbounds(outboundsFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		of := &models.OutboundsFile{}
		if err := loadJSONFile(outboundsFile, of); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, of)
	}
}

func APIAddOutbound(outboundsFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req struct {
			Name   string                 `json:"name" form:"name"`
			Type   string                 `json:"type" form:"type"`
			Config map[string]interface{} `json:"config" form:"config"`
		}
		if err := c.ShouldBind(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效参数"})
			return
		}

		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "add-outbound", req.Name, req.Type)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败: " + output})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "出站添加成功"})
	}
}

func APIDeleteOutbound(outboundsFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id := c.Param("id")
		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "delete-outbound", id)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败: " + output})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "出站已删除"})
	}
}

func APIEditOutbound(outboundsFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id := c.Param("id")
		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "edit-outbound", id)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "编辑失败: " + output})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "出站已更新"})
	}
}

// ============================================================================
// Traffic
// ============================================================================

func GetTrafficPage(usersFile, trafficFile string) gin.H {
	uf := &models.UsersFile{}
	loadJSONFile(usersFile, uf)
	tf := &models.TrafficFile{}
	loadJSONFile(trafficFile, tf)

	type TrafficRow struct {
		Username string
		Down     string
		Up       string
		Total    string
		Limit    string
	}

	var rows []TrafficRow
	for _, u := range uf.Users {
		total := u.TrafficUsedDown + u.TrafficUsedUp
		if total == 0 {
			continue
		}
		rows = append(rows, TrafficRow{
			Username: u.Username,
			Down:     formatBytes(u.TrafficUsedDown),
			Up:       formatBytes(u.TrafficUsedUp),
			Total:    formatBytes(total),
			Limit:    formatBytes(u.TrafficLimitBytes),
		})
	}

	return gin.H{
		"title":     "流量统计 - Sing-box Manager",
		"traffics":  rows,
		"totalDown": formatBytes(tf.Total.Down),
		"totalUp":   formatBytes(tf.Total.Up),
		"total":     formatBytes(tf.Total.Down + tf.Total.Up),
	}
}

func APITraffic(usersFile, trafficFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.JSON(http.StatusOK, GetTrafficPage(usersFile, trafficFile))
	}
}

func APITrafficUser(usersFile, trafficFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		username := c.Param("username")
		uf := &models.UsersFile{}
		if err := loadJSONFile(usersFile, uf); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		u, ok := uf.Users[username]
		if !ok {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		total := u.TrafficUsedDown + u.TrafficUsedUp
		c.JSON(http.StatusOK, gin.H{
			"username": u.Username,
			"down":     u.TrafficUsedDown,
			"up":       u.TrafficUsedUp,
			"total":    total,
			"limit":    u.TrafficLimitBytes,
			"down_str": formatBytes(u.TrafficUsedDown),
			"up_str":   formatBytes(u.TrafficUsedUp),
			"total_str": formatBytes(total),
			"limit_str": formatBytes(u.TrafficLimitBytes),
		})
	}
}

// ============================================================================
// Reload
// ============================================================================

func APIReload(scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "reload")
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "重载失败: " + output})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "配置已重载", "output": output})
	}
}

// ============================================================================
// Status
// ============================================================================

func APIStatus(usersFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		uf := &models.UsersFile{}
		loadJSONFile(usersFile, uf)

		active := 0
		online := 0
		for _, u := range uf.Users {
			if u.Status == "active" {
				active++
			}
			if u.Online {
				online++
			}
		}

		c.JSON(http.StatusOK, gin.H{
			"total_users":  len(uf.Users),
			"active_users": active,
			"online_users": online,
		})
	}
}

// ============================================================================
// Subscription
// ============================================================================

func SubscriptionHandler(usersFile, settingsFile, scriptsDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		username := c.Param("username")
		token := c.Query("token")
		format := c.DefaultQuery("format", "link")

		uf := &models.UsersFile{}
		if err := loadJSONFile(usersFile, uf); err != nil {
			c.String(http.StatusNotFound, "用户不存在")
			return
		}

		u, ok := uf.Users[username]
		if !ok {
			c.String(http.StatusNotFound, "用户不存在")
			return
		}

		// 验证 token
		if token != "" && u.Subscription.Token != "" && token != u.Subscription.Token {
			c.String(http.StatusForbidden, "无效的订阅 token")
			return
		}

		if u.Status != "active" {
			c.String(http.StatusForbidden, "用户已禁用")
			return
		}

		// 生成订阅
		script := scriptsDir + "/manager.sh"
		output, err := runShell(script, "gen-sub", username, format)
		if err != nil {
			c.String(http.StatusInternalServerError, "生成订阅失败")
			return
		}

		// 如果是 base64 订阅 (用于 Clash/Sing-box 客户端)
		if format == "sing-box" || format == "clash-meta" || format == "clash" {
			c.Header("Content-Type", "text/plain; charset=utf-8")
			c.Header("Subscription-Userinfo", fmt.Sprintf("upload=%d; download=%d; total=%d",
				u.TrafficUsedUp, u.TrafficUsedDown, u.TrafficLimitBytes))
		}

		c.String(http.StatusOK, strings.TrimSpace(output))
	}
}

func APIListSubs(usersFile string) gin.HandlerFunc {
	return func(c *gin.Context) {
		uf := &models.UsersFile{}
		if err := loadJSONFile(usersFile, uf); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		type SubInfo struct {
			Username string `json:"username"`
			Protocol string `json:"protocol"`
			URL      string `json:"url"`
		}

		var subs []SubInfo
		for _, u := range uf.Users {
			if u.Status == "active" {
				subs = append(subs, SubInfo{
					Username: u.Username,
					Protocol: u.Protocol,
					URL:      u.Subscription.URL,
				})
			}
		}
		c.JSON(http.StatusOK, gin.H{"subscriptions": subs})
	}
}

// ============================================================================
// Settings Page
// ============================================================================

func GetSettingsPage(settingsFile string) gin.H {
	s := &Settings{}
	loadJSONFile(settingsFile, s)

	return gin.H{
		"title":    "系统设置 - Sing-box Manager",
		"settings": s,
		"domain":   s.Domain,
		"webPort":  s.WebPort,
	}
}

// ============================================================================
// 未使用变量消除警告
// ============================================================================
var _ = math.MaxFloat64
var _ = template.HTML("")