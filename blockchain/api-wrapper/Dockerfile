# Group F SWMS — Blockchain API Wrapper Docker Image
# Builds the Go REST server that bridges HTTP to Hyperledger Fabric gRPC.
#
# Build (from blockchain/api-wrapper/):
#   docker build -t blockchain-api-wrapper:1.0 .
#
# Minikube local build:
#   eval $(minikube docker-env)
#   docker build -t blockchain-api-wrapper:1.0 blockchain/api-wrapper/

FROM golang:1.21-alpine AS builder

WORKDIR /build

COPY go.mod go.su[m] ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o api-wrapper .

# ── Runtime image ──────────────────────────────────────────────────
FROM alpine:3.19

RUN apk --no-cache add ca-certificates tzdata && \
    addgroup -S swms && adduser -S swms -G swms

USER swms
WORKDIR /home/swms

COPY --from=builder /build/api-wrapper /home/swms/api-wrapper

ENV PORT=8080
ENV GIN_MODE=release

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["/home/swms/api-wrapper"]
