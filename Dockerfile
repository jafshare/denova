# syntax=docker/dockerfile:1
#
# Denova 多阶段构建镜像
#   Stage 1: node + pnpm 构建前端（相对路径产物，根路径/子路径均可部署）
#   Stage 2: golang 构建 denova 二进制，并把前端产物内嵌（-tags embedweb），
#            镜像运行时不依赖 web/ 目录，单二进制即完整应用
#   Stage 3: 精简 alpine 运行镜像，内置 config.toml 默认开启局域网访问
#
# 构建参数:
#   VERSION   版本号（写入 internal/buildinfo.Version，由流水线传入，默认 dev）

########## Stage 1: 构建前端 ##########
FROM node:22-alpine AS web-builder
WORKDIR /src/web
# 先复制依赖清单以利用 Docker 层缓存
COPY web/package.json web/pnpm-lock.yaml ./
RUN npm install -g pnpm@9 && pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm build

########## Stage 2: 编译 denova（内嵌前端） ##########
FROM golang:1.26-alpine AS go-builder
ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# 前端产物从 Stage 1 直接拷贝（.dockerignore 已排除 web/dist，避免上下文携带本地产物）
COPY --from=web-builder /src/web/dist ./web/dist
RUN cp -r web/dist internal/webfs/dist \
 && CGO_ENABLED=0 go build -tags embedweb \
      -ldflags "-X denova/internal/buildinfo.Version=${VERSION}" \
      -o /out/denova ./cmd/denova/ \
 && CGO_ENABLED=0 go build \
      -ldflags "-X denova/internal/buildinfo.Version=${VERSION}" \
      -o /out/denova-updater ./cmd/denova-updater/

########## Stage 3: 运行镜像 ##########
FROM alpine:3.22
# ca-certificates: 访问 OpenAI 等外部 HTTPS API；tzdata: 时区；wget: 健康检查
RUN apk add --no-cache ca-certificates wget tzdata \
 && addgroup -S denova && adduser -S -G denova denova

WORKDIR /app
COPY --from=go-builder /out/denova /out/denova-updater ./
COPY docker/config.toml ./config.toml
COPY skills ./skills

# 数据目录：denova 状态（.denova）与作品工作区（/workspace）
# 通过 VOLUME 持久化；挂载自定义配置时可用 -v /host/config.toml:/app/config.toml
RUN mkdir -p /workspace /app/.denova /app/log \
 && chown -R denova:denova /app /workspace

USER denova

ENV DENOVA_WORKSPACE=/workspace \
    DENOVA_BACKEND_PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/api/status >/dev/null 2>&1 || exit 1

CMD ["/app/denova", "--no-open"]
