package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

func AuthMiddleware(jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		// 检查 cookie
		tokenStr, err := c.Cookie("sb_token")
		if err != nil {
			// 检查 Authorization header
			authHeader := c.GetHeader("Authorization")
			if strings.HasPrefix(authHeader, "Bearer ") {
				tokenStr = strings.TrimPrefix(authHeader, "Bearer ")
			}
		}

		if tokenStr == "" {
			// HTMX 请求返回 401, 普通请求重定向
			if c.GetHeader("HX-Request") == "true" {
				c.Header("HX-Redirect", "/login")
				c.Status(http.StatusUnauthorized)
			} else {
				c.Redirect(http.StatusFound, "/login")
			}
			c.Abort()
			return
		}

		token, err := jwt.Parse(tokenStr, func(token *jwt.Token) (interface{}, error) {
			return []byte(jwtSecret), nil
		})

		if err != nil || !token.Valid {
			if c.GetHeader("HX-Request") == "true" {
				c.Header("HX-Redirect", "/login")
				c.Status(http.StatusUnauthorized)
			} else {
				c.Redirect(http.StatusFound, "/login")
			}
			c.Abort()
			return
		}

		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}

		c.Set("username", claims["username"])
		c.Next()
	}
}