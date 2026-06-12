package main

import (
	"embed"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"

	"sb-manager-web/handlers"
	"sb-manager-web/middleware"

	"github.com/gin-gonic/gin"
)

//go:embed templates/*
var templatesFS embed.FS

//go:embed static/*
var staticFS embed.FS

const (
	BaseDir      = "/opt/sb-manager"
	DataDir      = BaseDir + "/core/data"
	UsersFile    = DataDir + "/users.json"
	OutboundsFile = DataDir + "/outbounds.json"
	TrafficFile  = DataDir + "/traffic.json"
	SettingsFile = DataDir + "/settings.json"
	ScriptsDir   = BaseDir + "/scripts"
)

func main() {
	// 初始化目录
	os.MkdirAll(DataDir, 0755)

	// 读取设置
	settings, err := handlers.LoadSettings(SettingsFile)
	if err != nil {
		log.Printf("警告: 无法读取设置: %v", err)
		settings = &handlers.Settings{
			WebPort:      "2053",
			WebUsername:  "admin",
			WebPasswordHash: "",
			JWTSecret:    "default-secret-change-me",
		}
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.Default()

	// 静态文件
	staticSub, _ := fs.Sub(staticFS, "static")
	r.StaticFS("/static", http.FS(staticSub))

	// 加载模板
	tmpl := template.Must(template.New("").ParseFS(templatesFS, "templates/*.html"))
	r.SetHTMLTemplate(tmpl)

	// 公开路由
	r.GET("/login", func(c *gin.Context) {
		c.HTML(http.StatusOK, "login.html", gin.H{"title": "登录 - Sing-box Manager"})
	})
	r.POST("/api/login", handlers.Login(settings))

	// 订阅路由 (公开)
	r.GET("/sub/:username", handlers.SubscriptionHandler(UsersFile, SettingsFile, ScriptsDir))

	// 需要认证的路由
	auth := r.Group("/")
	auth.Use(middleware.AuthMiddleware(settings.JWTSecret))
	{
		// 页面路由
		auth.GET("/", func(c *gin.Context) {
			c.HTML(http.StatusOK, "dashboard.html", handlers.GetDashboard(UsersFile, OutboundsFile, TrafficFile))
		})
		auth.GET("/dashboard", func(c *gin.Context) {
			c.HTML(http.StatusOK, "dashboard.html", handlers.GetDashboard(UsersFile, OutboundsFile, TrafficFile))
		})
		auth.GET("/users", func(c *gin.Context) {
			c.HTML(http.StatusOK, "users.html", handlers.GetUsersPage(UsersFile))
		})
		auth.GET("/outbounds", func(c *gin.Context) {
			c.HTML(http.StatusOK, "outbounds.html", handlers.GetOutboundsPage(OutboundsFile))
		})
		auth.GET("/traffic", func(c *gin.Context) {
			c.HTML(http.StatusOK, "traffic.html", handlers.GetTrafficPage(UsersFile, TrafficFile))
		})
		auth.GET("/settings", func(c *gin.Context) {
			c.HTML(http.StatusOK, "settings.html", handlers.GetSettingsPage(SettingsFile))
		})

		// API 路由
		api := auth.Group("/api")
		{
			api.GET("/dashboard", handlers.APIDashboard(UsersFile, OutboundsFile, TrafficFile))

			// 用户管理
			api.GET("/users", handlers.APIListUsers(UsersFile))
			api.POST("/users", handlers.APIAddUser(UsersFile, ScriptsDir))
			api.DELETE("/users/:username", handlers.APIDeleteUser(UsersFile, ScriptsDir))
			api.PUT("/users/:username", handlers.APIEditUser(UsersFile, ScriptsDir))
			api.GET("/users/:username/config", handlers.APIGetUserConfig(UsersFile, ScriptsDir))

			// 出站管理
			api.GET("/outbounds", handlers.APIListOutbounds(OutboundsFile))
			api.POST("/outbounds", handlers.APIAddOutbound(OutboundsFile, ScriptsDir))
			api.DELETE("/outbounds/:id", handlers.APIDeleteOutbound(OutboundsFile, ScriptsDir))
			api.PUT("/outbounds/:id", handlers.APIEditOutbound(OutboundsFile, ScriptsDir))

			// 流量统计
			api.GET("/traffic", handlers.APITraffic(UsersFile, TrafficFile))
			api.GET("/traffic/:username", handlers.APITrafficUser(UsersFile, TrafficFile))

			// 系统操作
			api.POST("/reload", handlers.APIReload(ScriptsDir))
			api.GET("/status", handlers.APIStatus(UsersFile))

			// 订阅
			api.GET("/subs", handlers.APIListSubs(UsersFile))
		}
	}

	// 启动服务
	addr := ":" + settings.WebPort
	log.Printf("Web 管理面板启动: http://0.0.0.0%s", addr)
	if err := r.Run(addr); err != nil {
		log.Fatalf("服务启动失败: %v", err)
	}
}

// runShell is a helper to execute shell scripts
func runShell(script string, args ...string) (string, error) {
	cmdArgs := append([]string{script}, args...)
	cmd := exec.Command("bash", cmdArgs...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}