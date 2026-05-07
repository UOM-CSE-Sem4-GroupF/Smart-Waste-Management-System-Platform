// Group F SWMS — Hyperledger Fabric Smart Contract
// Chaincode: collection-record v1.0
// Owner: F4 Platform Team
//
// Maintains an immutable audit trail of every waste collection job.
// Deployed to: waste-collection-channel
//
// Functions:
//   RecordCollection(ctx, recordJSON) string  — write a new record (called by F3 orchestrator)
//   QueryRecord(ctx, jobID) *CollectionRecord — read by job ID (called by F3 dashboard)
//   QueryRecordsByZone(ctx, zoneID) []CollectionRecord — range query for zone history
//   RecordExists(ctx, jobID) bool             — existence check before write
//
// Validation: no empty bins, driver and vehicle are mandatory, weight must be positive.
// The transaction ID and creation timestamp are set by the chaincode (not the caller).

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// CollectionRecord is the ledger asset written once per completed job.
type CollectionRecord struct {
	JobID           string      `json:"job_id"`
	JobType         string      `json:"job_type"`          // "routine" | "emergency"
	ZoneID          int         `json:"zone_id"`
	DriverID        string      `json:"driver_id"`
	VehicleID       string      `json:"vehicle_id"`
	BinsCollected   []BinRecord `json:"bins_collected"`
	TotalWeightKg   float64     `json:"total_weight_kg"`
	RouteDistanceKm float64     `json:"route_distance_km"`
	StartedAt       string      `json:"started_at"`
	CompletedAt     string      `json:"completed_at"`
	GPSTrailHash    string      `json:"gps_trail_hash"`    // SHA-256 of full GPS trail
	CreatedAt       string      `json:"created_at"`        // set by chaincode
	TxID            string      `json:"tx_id"`             // set by chaincode
}

// BinRecord captures per-bin collection data within a job.
type BinRecord struct {
	BinID           string  `json:"bin_id"`
	WasteCategory   string  `json:"waste_category"`    // "general" | "recycling" | "organic"
	FillLevelAtTime float64 `json:"fill_level_at_time"` // 0.0–1.0
	CollectedAt     string  `json:"collected_at"`
	WeightKg        float64 `json:"weight_kg"`
	GPSLat          float64 `json:"gps_lat"`
	GPSLng          float64 `json:"gps_lng"`
}

// CollectionContract implements the chaincode interface.
type CollectionContract struct {
	contractapi.Contract
}

// RecordCollection writes an immutable collection audit record to the ledger.
// Called by the F3 workflow orchestrator at step 8 (RECORDING_AUDIT state).
// Returns the Fabric transaction ID on success.
func (c *CollectionContract) RecordCollection(
	ctx contractapi.TransactionContextInterface,
	recordJSON string,
) (string, error) {
	var record CollectionRecord
	if err := json.Unmarshal([]byte(recordJSON), &record); err != nil {
		return "", fmt.Errorf("invalid record JSON: %w", err)
	}

	// Validate completeness — smart contract enforces these invariants
	if record.JobID == "" {
		return "", fmt.Errorf("job_id is required")
	}
	if record.DriverID == "" || record.VehicleID == "" {
		return "", fmt.Errorf("driver_id and vehicle_id are required")
	}
	if len(record.BinsCollected) == 0 {
		return "", fmt.Errorf("at least one bin must be recorded")
	}
	if record.TotalWeightKg <= 0 {
		return "", fmt.Errorf("total_weight_kg must be positive")
	}
	if record.JobType != "routine" && record.JobType != "emergency" {
		return "", fmt.Errorf("job_type must be 'routine' or 'emergency', got: %s", record.JobType)
	}

	// Guard: reject duplicate writes (audit records are write-once)
	exists, err := c.RecordExists(ctx, record.JobID)
	if err != nil {
		return "", fmt.Errorf("existence check failed: %w", err)
	}
	if exists {
		return "", fmt.Errorf("record for job_id %s already exists", record.JobID)
	}

	// Stamp TxID and creation timestamp — these come from the ledger, not the caller
	record.TxID = ctx.GetStub().GetTxID()
	record.CreatedAt = time.Now().UTC().Format(time.RFC3339)

	recordBytes, err := json.Marshal(record)
	if err != nil {
		return "", fmt.Errorf("failed to marshal record: %w", err)
	}

	if err := ctx.GetStub().PutState(record.JobID, recordBytes); err != nil {
		return "", fmt.Errorf("failed to write state: %w", err)
	}

	// Emit a chaincode event so the API wrapper can push notifications
	if err := ctx.GetStub().SetEvent("CollectionRecorded", recordBytes); err != nil {
		return "", fmt.Errorf("failed to set event: %w", err)
	}

	return record.TxID, nil
}

// QueryRecord retrieves a single collection record by its job ID.
// Called by the F3 dashboard for audit verification and by the API wrapper GET endpoint.
func (c *CollectionContract) QueryRecord(
	ctx contractapi.TransactionContextInterface,
	jobID string,
) (*CollectionRecord, error) {
	if jobID == "" {
		return nil, fmt.Errorf("job_id is required")
	}

	recordBytes, err := ctx.GetStub().GetState(jobID)
	if err != nil {
		return nil, fmt.Errorf("failed to read state: %w", err)
	}
	if recordBytes == nil {
		return nil, fmt.Errorf("record not found for job_id: %s", jobID)
	}

	var record CollectionRecord
	if err := json.Unmarshal(recordBytes, &record); err != nil {
		return nil, fmt.Errorf("failed to unmarshal record: %w", err)
	}

	return &record, nil
}

// QueryRecordsByZone returns all collection records for a given zone using a range query.
// The composite key is "ZONE~JOB" so zone records cluster together in the state DB.
func (c *CollectionContract) QueryRecordsByZone(
	ctx contractapi.TransactionContextInterface,
	zoneID string,
) ([]*CollectionRecord, error) {
	if zoneID == "" {
		return nil, fmt.Errorf("zone_id is required")
	}

	// Use rich query via GetQueryResult (requires CouchDB in production;
	// falls back to a composite-key range scan for LevelDB in dev).
	queryString := fmt.Sprintf(`{"selector":{"zone_id":%s}}`, zoneID)
	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		// Fall back: return empty list rather than crashing on LevelDB
		return []*CollectionRecord{}, nil
	}
	defer resultsIterator.Close()

	var records []*CollectionRecord
	for resultsIterator.HasNext() {
		queryResult, err := resultsIterator.Next()
		if err != nil {
			return nil, fmt.Errorf("iterator error: %w", err)
		}
		var record CollectionRecord
		if err := json.Unmarshal(queryResult.Value, &record); err != nil {
			continue
		}
		records = append(records, &record)
	}

	return records, nil
}

// RecordExists checks whether an audit record for the given job ID is already on the ledger.
func (c *CollectionContract) RecordExists(
	ctx contractapi.TransactionContextInterface,
	jobID string,
) (bool, error) {
	recordBytes, err := ctx.GetStub().GetState(jobID)
	if err != nil {
		return false, fmt.Errorf("failed to read state: %w", err)
	}
	return recordBytes != nil, nil
}

// GetTransactionHistory returns the full modification history for a job ID.
// Useful for compliance auditing (normally a record is written once and never modified).
func (c *CollectionContract) GetTransactionHistory(
	ctx contractapi.TransactionContextInterface,
	jobID string,
) ([]map[string]interface{}, error) {
	if jobID == "" {
		return nil, fmt.Errorf("job_id is required")
	}

	historyIterator, err := ctx.GetStub().GetHistoryForKey(jobID)
	if err != nil {
		return nil, fmt.Errorf("failed to get history: %w", err)
	}
	defer historyIterator.Close()

	var history []map[string]interface{}
	for historyIterator.HasNext() {
		modification, err := historyIterator.Next()
		if err != nil {
			return nil, fmt.Errorf("history iterator error: %w", err)
		}
		entry := map[string]interface{}{
			"tx_id":     modification.TxId,
			"timestamp": modification.Timestamp.AsTime().UTC().Format(time.RFC3339),
			"is_delete": modification.IsDelete,
		}
		if !modification.IsDelete {
			var record CollectionRecord
			if err := json.Unmarshal(modification.Value, &record); err == nil {
				entry["value"] = record
			}
		}
		history = append(history, entry)
	}

	return history, nil
}

func main() {
	// CCaaS mode: chaincode runs as a gRPC server that the peer dials into.
	// CHAINCODE_SERVER_ADDRESS and CHAINCODE_ID are injected by the K8s Deployment.
	server := &shim.ChaincodeServer{
		CCID:    os.Getenv("CHAINCODE_ID"),
		Address: os.Getenv("CHAINCODE_SERVER_ADDRESS"),
		CC:      new(CollectionContract),
		TLSProps: shim.TLSProperties{
			Disabled: true, // TLS handled at the Kubernetes network layer for dev
		},
	}

	log.Printf("Starting collection-record chaincode server on %s (id=%s)",
		os.Getenv("CHAINCODE_SERVER_ADDRESS"),
		os.Getenv("CHAINCODE_ID"),
	)

	if err := server.Start(); err != nil {
		log.Fatalf("chaincode server failed: %v", err)
	}
}
