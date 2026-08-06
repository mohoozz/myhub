// Package config 负责应用配置的加载与管理。
// 使用 Viper 读取 config.yaml，支持环境变量覆盖（前缀 MYHUB）。
package config

import (
	"strings"

	"github.com/spf13/viper"
)

// Config 应用全局配置
type Config struct {
	Server   ServerConfig   `mapstructure:"server"`
	JWT      JWTConfig      `mapstructure:"jwt"`
	Database DatabaseConfig `mapstructure:"database"`
	Storage  StorageConfig  `mapstructure:"storage"`
	Data     DataConfig     `mapstructure:"data"`
	Internal InternalConfig `mapstructure:"internal"`
	Trash    TrashConfig    `mapstructure:"trash"`
	Web      WebConfig      `mapstructure:"web"`
}

// ServerConfig HTTP 服务配置
type ServerConfig struct {
	Port int    `mapstructure:"port"` // 监听端口，默认 8080
	Mode string `mapstructure:"mode"` // Gin 运行模式：debug / release
}

// JWTConfig JWT 鉴权配置
type JWTConfig struct {
	Secret      string `mapstructure:"secret"`      // JWT 签名密钥
	ExpireHours int    `mapstructure:"expire_hours"` // Token 过期时间（小时），默认 24
}

// DatabaseConfig 数据库配置
type DatabaseConfig struct {
	Path string `mapstructure:"path"` // SQLite 数据库文件路径，默认 data/myhub.db
}

// StorageConfig 存储配置
type StorageConfig struct {
	AllowedRoots []string `mapstructure:"allowed_roots"` // 路径源白名单，本地路径源仅允许这些根目录
}

// DataConfig 数据目录配置
type DataConfig struct {
	ThumbsDir  string `mapstructure:"thumbs_dir"`  // 视频缩略图缓存目录
	HLSDir     string `mapstructure:"hls_dir"`     // HLS 转码输出目录
	AvatarsDir string `mapstructure:"avatars_dir"` // 用户头像存储目录
}

// InternalConfig 内部接口配置（供 OpenClaw 等内部服务回传）
type InternalConfig struct {
	Token string `mapstructure:"token"` // 内部接口访问令牌，请求头 X-Internal-Token 携带
}

// TrashConfig 回收站配置
type TrashConfig struct {
	RetentionDays int `mapstructure:"retention_days"` // 保留天数，超时自动清理，默认 30
}

// WebConfig Flutter Web 静态托管配置
type WebConfig struct {
	Dir string `mapstructure:"dir"` // Flutter Web 构建产物目录；为空则不托管
}

// Load 加载配置文件，并应用默认值与环境变量覆盖。
// configPath 为空时默认读取当前目录下的 config.yaml。
func Load(configPath string) (*Config, error) {
	v := viper.New()

	// 配置文件设置
	if configPath != "" {
		v.SetConfigFile(configPath)
	} else {
		v.SetConfigName("config")
		v.SetConfigType("yaml")
		v.AddConfigPath(".")
		v.AddConfigPath("./config")
	}

	// 默认值兜底
	v.SetDefault("server.port", 8080)
	v.SetDefault("server.mode", "debug")
	v.SetDefault("jwt.secret", "myhub-default-secret-please-change")
	v.SetDefault("jwt.expire_hours", 24)
	v.SetDefault("database.path", "data/myhub.db")
	v.SetDefault("storage.allowed_roots", []string{})
	v.SetDefault("data.thumbs_dir", "data/thumbs")
	v.SetDefault("data.hls_dir", "data/hls")
	v.SetDefault("data.avatars_dir", "data/avatars")
	v.SetDefault("internal.token", "myhub-internal-token-please-change")
	v.SetDefault("trash.retention_days", 30)
	v.SetDefault("web.dir", "")

	// 环境变量覆盖：前缀 MYHUB，"." 替换为 "_"
	// 例如 MYHUB_SERVER_PORT 覆盖 server.port
	v.SetEnvPrefix("MYHUB")
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()

	// 配置文件不存在时不视为错误，使用默认值 + 环境变量
	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			// SetConfigFile 指定路径时，文件不存在返回的是 *os.PathError
			// 仅在明确指定了配置文件且读取失败时才报错
			if configPath != "" {
				return nil, err
			}
		}
	}

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
