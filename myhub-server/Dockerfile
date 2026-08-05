# syntax=docker/dockerfile:1

# ---------- 构建阶段 ----------
FROM golang:1-alpine AS builder

WORKDIR /build

# 配置国内模块代理（构建参数可覆盖）
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

# 优先拷贝依赖清单，利用 Docker 层缓存
COPY go.mod go.sum ./
RUN go mod download

# 拷贝源码并编译（纯 Go SQLite 驱动，关闭 CGO）
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/myhub-server ./cmd/server

# ---------- 运行阶段 ----------
FROM alpine:3.21

# ffmpeg：视频抽帧缩略图 / HLS 转码；ca-certificates：HTTPS 请求（WebDAV 等）
RUN apk add --no-cache ffmpeg ca-certificates tzdata

WORKDIR /app

COPY --from=builder /out/myhub-server /app/myhub-server
COPY config.yaml /app/config.yaml

# 数据目录：SQLite 数据库、缩略图、HLS 转码产物
VOLUME ["/data"]

EXPOSE 8080

# 容器内默认使用 /data 存放数据，可通过环境变量覆盖
ENV MYHUB_SERVER_MODE=release \
    MYHUB_DATABASE_PATH=/data/myhub.db \
    MYHUB_DATA_THUMBS_DIR=/data/thumbs \
    MYHUB_DATA_HLS_DIR=/data/hls

ENTRYPOINT ["/app/myhub-server"]
