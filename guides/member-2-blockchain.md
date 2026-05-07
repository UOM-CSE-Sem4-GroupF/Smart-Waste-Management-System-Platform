# Member 2: Blockchain Infrastructure Specialist
## Domain: Hyperledger Fabric Implementation (Section 13)

### 📋 Overview
Your goal is to build the immutable audit trail for the Smart Waste Management System. This ensures that every job completion is cryptographically signed and verifiable.

### 🛠️ Key Tasks
1. **Deploy Blockchain Network**
   - Deploy Peer, Orderer, and CA nodes in the `blockchain` namespace.
   - Configure persistent volume claims (PVCs) for the ledger data.
2. **Channel & Chaincode**
   - Initialize the `waste-collection-channel`.
   - Deploy the `collection-record.go` chaincode to the channel.
3. **Go SDK REST Wrapper**
   - Develop a REST API using the Hyperledger Fabric Go SDK.
   - Expose endpoints: `POST /records` (internal) and `GET /records/:id` (public via Kong).

### 📖 Reference Paths
- **Manifests:** `blockchain/network/`
- **Smart Contracts:** `blockchain/chaincode/`
- **SDK App:** `blockchain/api-wrapper/`

### 💡 Pro-Tips
- Use the **Fabric Operations Console** if you need a UI to manage the nodes.
- Ensure mTLS is enforced for all Peer-to-Peer communication.
