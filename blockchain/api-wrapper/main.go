// Group F SWMS — Hyperledger Fabric REST API Wrapper
// Owner: F4 Platform Team
// Service 18 — blockchain/api-wrapper
//
// Bridges HTTP (Kong → F3 orchestrator / dashboard) to the Fabric peer gRPC.
// Uses the fabric-gateway SDK (Fabric 2.4+ native gateway protocol).
//
// Endpoints:
//   POST /records            — submit a collection audit record (internal, called by F3)
//   GET  /records/:job_id   — query a record by job ID (public via Kong JWT)
//   GET  /records/zone/:id  — query all records for a zone (public via Kong JWT)
//   GET  /health             — liveness check
//
// Auth: Kong enforces JWT on all /api/v1/* routes. This service trusts Kong and
//       does not re-validate tokens. Internal callers (F3 orchestrator) call
//       directly via K8s DNS bypassing Kong.
//
// Env vars:
//   PEER_ENDPOINT          — peer gRPC address (default: peer0.blockchain.svc.cluster.local:7051)
//   PEER_TLS_CERT_PATH     — path to peer TLS root cert PEM
//   PEER_HOSTNAME_OVERRIDE — TLS hostname override for peer (default: peer0.wasteMgmt.swms.local)
//   ADMIN_CERT_PATH        — path to admin signing cert PEM
//   ADMIN_KEY_PATH         — path to admin private key PEM
//   MSP_ID                 — Fabric MSP ID (default: WasteMgmtMSP)
//   CHANNEL_NAME           — channel (default: waste-collection-channel)
//   CHAINCODE_NAME         — chaincode (default: collection-record)
//   PORT                   — HTTP listen port (default: 8080)

package main

import (
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/hash"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// ── Domain types (must match collection-record.go in chaincode/) ──────────────

type BinRecord struct {
	BinID           string  `json:"bin_id"`
	WasteCategory   string  `json:"waste_category"`
	FillLevelAtTime float64 `json:"fill_level_at_time"`
	CollectedAt     string  `json:"collected_at"`
	WeightKg        float64 `json:"weight_kg"`
	GPSLat          float64 `json:"gps_lat"`
	GPSLng          float64 `json:"gps_lng"`
}

type CollectionRecord struct {
	JobID           string      `json:"job_id"`
	JobType         string      `json:"job_type"`
	ZoneID          int         `json:"zone_id"`
	DriverID        string      `json:"driver_id"`
	VehicleID       string      `json:"vehicle_id"`
	BinsCollected   []BinRecord `json:"bins_collected"`
	TotalWeightKg   float64     `json:"total_weight_kg"`
	RouteDistanceKm float64     `json:"route_distance_km"`
	StartedAt       string      `json:"started_at"`
	CompletedAt     string      `json:"completed_at"`
	GPSTrailHash    string      `json:"gps_trail_hash"`
	CreatedAt       string      `json:"created_at"`
	TxID            string      `json:"tx_id"`
}

// ── Fabric gateway singleton ──────────────────────────────────────────────────

var fabricContract *client.Contract

func initFabricGateway() error {
	peerEndpoint := env("PEER_ENDPOINT", "peer0.blockchain.svc.cluster.local:7051")
	tlsCertPath := env("PEER_TLS_CERT_PATH", "/etc/fabric/tls/peer-tlsca.pem")
	hostnameOverride := env("PEER_HOSTNAME_OVERRIDE", "peer0.wasteMgmt.swms.local")
	adminCertPath := env("ADMIN_CERT_PATH", "/etc/fabric/identity/cert.pem")
	adminKeyPath := env("ADMIN_KEY_PATH", "/etc/fabric/identity/key.pem")
	mspID := env("MSP_ID", "WasteMgmtMSP")
	channelName := env("CHANNEL_NAME", "waste-collection-channel")
	chaincodeName := env("CHAINCODE_NAME", "collection-record")

	// Load peer TLS root cert for mTLS
	tlsCertPEM, err := os.ReadFile(tlsCertPath)
	if err != nil {
		return fmt.Errorf("read peer TLS cert %s: %w", tlsCertPath, err)
	}
	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(tlsCertPEM) {
		return fmt.Errorf("failed to parse peer TLS cert")
	}
	tlsCreds := credentials.NewClientTLSFromCert(certPool, hostnameOverride)

	conn, err := grpc.NewClient(peerEndpoint,
		grpc.WithTransportCredentials(tlsCreds),
	)
	if err != nil {
		return fmt.Errorf("gRPC dial %s: %w", peerEndpoint, err)
	}

	// Load admin identity (signing cert + private key)
	certPEM, err := os.ReadFile(adminCertPath)
	if err != nil {
		return fmt.Errorf("read admin cert %s: %w", adminCertPath, err)
	}
	keyPEM, err := os.ReadFile(adminKeyPath)
	if err != nil {
		return fmt.Errorf("read admin key %s: %w", adminKeyPath, err)
	}

	id, err := identity.NewX509Identity(mspID, certPEM)
	if err != nil {
		return fmt.Errorf("create X509 identity: %w", err)
	}
	privateKey, err := identity.PrivateKeyFromPEM(keyPEM)
	if err != nil {
		return fmt.Errorf("parse private key: %w", err)
	}
	sign, err := identity.NewPrivateKeySign(privateKey)
	if err != nil {
		return fmt.Errorf("create signer: %w", err)
	}

	gw, err := client.Connect(
		id,
		client.WithSign(sign),
		client.WithHash(hash.SHA256),
		client.WithClientConnection(conn),
		client.WithEvaluateTimeout(5*time.Second),
		client.WithEndorseTimeout(15*time.Second),
		client.WithSubmitTimeout(5*time.Second),
		client.WithCommitStatusTimeout(1*time.Minute),
	)
	if err != nil {
		return fmt.Errorf("fabric gateway connect: %w", err)
	}

	fabricContract = gw.GetNetwork(channelName).GetContract(chaincodeName)
	log.Printf("Fabric gateway ready — peer=%s channel=%s chaincode=%s",
		peerEndpoint, channelName, chaincodeName)
	return nil
}

// ── HTTP handlers ─────────────────────────────────────────────────────────────

// POST /records
// Body: CollectionRecord JSON (from F3 workflow orchestrator)
// Returns: { "tx_id": "abc123..." }
func postRecord(c *gin.Context) {
	var record CollectionRecord
	if err := c.ShouldBindJSON(&record); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid JSON: " + err.Error()})
		return
	}

	recordBytes, err := json.Marshal(record)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "marshal error"})
		return
	}

	result, err := fabricContract.SubmitTransaction("RecordCollection", string(recordBytes))
	if err != nil {
		log.Printf("RecordCollection failed: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": extractFabricError(err)})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"tx_id": string(result)})
}

// GET /records/:job_id
// Returns the full CollectionRecord for a job ID (for dashboard audit view).
func getRecord(c *gin.Context) {
	jobID := c.Param("job_id")
	if jobID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "job_id is required"})
		return
	}

	result, err := fabricContract.EvaluateTransaction("QueryRecord", jobID)
	if err != nil {
		if isNotFound(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "record not found for job_id: " + jobID})
			return
		}
		log.Printf("QueryRecord failed for %s: %v", jobID, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": extractFabricError(err)})
		return
	}

	var record CollectionRecord
	if err := json.Unmarshal(result, &record); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "unmarshal error"})
		return
	}

	c.JSON(http.StatusOK, record)
}

// GET /records/zone/:zone_id
// Returns all collection records for the given zone (for dashboard history view).
func getRecordsByZone(c *gin.Context) {
	zoneID := c.Param("zone_id")
	if zoneID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "zone_id is required"})
		return
	}

	result, err := fabricContract.EvaluateTransaction("QueryRecordsByZone", zoneID)
	if err != nil {
		log.Printf("QueryRecordsByZone failed for zone %s: %v", zoneID, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": extractFabricError(err)})
		return
	}

	var records []CollectionRecord
	if err := json.Unmarshal(result, &records); err != nil {
		// Empty result set from chaincode returns null — treat as empty array
		c.JSON(http.StatusOK, []CollectionRecord{})
		return
	}

	c.JSON(http.StatusOK, records)
}

// GET /records/:job_id/history
// Returns the full transaction history for a job ID (normally one entry).
func getRecordHistory(c *gin.Context) {
	jobID := c.Param("job_id")
	if jobID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "job_id is required"})
		return
	}

	result, err := fabricContract.EvaluateTransaction("GetTransactionHistory", jobID)
	if err != nil {
		log.Printf("GetTransactionHistory failed for %s: %v", jobID, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": extractFabricError(err)})
		return
	}

	var history []map[string]interface{}
	if err := json.Unmarshal(result, &history); err != nil {
		c.JSON(http.StatusOK, []map[string]interface{}{})
		return
	}

	c.JSON(http.StatusOK, history)
}

// GET /health
func health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "ok",
		"service": "blockchain-api-wrapper",
		"version": "1.0.0",
	})
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func env(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func extractFabricError(err error) string {
	return err.Error()
}

func isNotFound(err error) bool {
	return err != nil && contains(err.Error(), "record not found")
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && (func() bool {
		for i := 0; i <= len(s)-len(sub); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})())
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main() {
	if err := initFabricGateway(); err != nil {
		log.Fatalf("Failed to initialise Fabric gateway: %v", err)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	r.GET("/health", health)

	// Internal — called directly by F3 orchestrator via K8s DNS (no Kong JWT)
	r.POST("/records", postRecord)

	// Public — routed through Kong with strip_path: false, so full /api/v1/records/* path arrives here
	r.GET("/api/v1/records/zone/:zone_id", getRecordsByZone)
	r.GET("/api/v1/records/:job_id/history", getRecordHistory)
	r.GET("/api/v1/records/:job_id", getRecord)

	port := env("PORT", "8080")
	log.Printf("blockchain-api-wrapper listening on :%s", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
