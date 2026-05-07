# Group F SWMS — Chaincode Docker Image
# Builds the collection-record chaincode as a CCaaS (Chaincode-as-a-Service) binary.
#
# Build (from repo root, with Minikube Docker env for local dev):
#   eval $(minikube docker-env)
#   docker build -t collection-record-cc:1.0 blockchain/chaincode/
#
# The resulting image is referenced in blockchain/network/05-chaincode-server.yaml.

FROM golang:1.21-alpine AS builder

WORKDIR /build

# Cache dependencies separately from source
COPY go.mod go.sum ./
RUN go mod download

COPY collection-record.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o chaincode .

# ── Runtime image ──────────────────────────────────────────────────
FROM alpine:3.19

RUN apk --no-cache add ca-certificates && \
    addgroup -S fabric && adduser -S fabric -G fabric

USER fabric
WORKDIR /home/fabric

COPY --from=builder /build/chaincode /home/fabric/chaincode

# CCaaS environment variables (overridden by K8s Deployment)
ENV CHAINCODE_SERVER_ADDRESS=0.0.0.0:7052
ENV CHAINCODE_ID=""

EXPOSE 7052

ENTRYPOINT ["/home/fabric/chaincode"]
