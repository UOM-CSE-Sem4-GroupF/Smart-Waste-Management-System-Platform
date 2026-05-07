# Jaeger Distributed Tracing

## Trace Propagation Flow

## Headers Used
| Header | Purpose |
|--------|---------|
| `X-B3-TraceId` | Unique trace identifier |
| `X-B3-SpanId` | Current span identifier |
| `X-B3-ParentSpanId` | Parent span reference |
| `X-B3-Sampled` | Whether this trace is sampled |

## Accessing Jaeger UI
```bash
kubectl port-forward svc/jaeger 16686:16686 -n monitoring
# Open http://localhost:16686
```

## Verifying Traces
1. Send a request through Kong Gateway
2. Open Jaeger UI → Search by service: `kong-gateway`
3. You should see a complete trace spanning all 4 services
