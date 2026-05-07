import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 200 }, // Ramp-up to 200 virtual users
    { duration: '3m', target: 200 }, // Stay at 200 for 3 minutes
    { duration: '1m', target: 0 },   // Ramp-down to 0
  ],
  thresholds: {
    'http_req_duration': ['p(95)<500'], // 95% of requests must complete below 500ms
    'http_req_failed': ['rate<0.01'],   // Request failure rate should be less than 1%
  },
};

// The main function for the test
export default function () {
  // For local Minikube setup, the Kong proxy URL would be determined by `minikube service kong-kong-proxy -n gateway`
  // For DOKS, it would be the LoadBalancer IP.
  // We'll use a placeholder that should be configured in the environment.
  const apiUrl = __ENV.API_URL || 'http://localhost:30080'; // Default to local NodePort from values-dev.yaml

  // Target a sample public endpoint. Let's assume a '/status' endpoint on the core-api service.
  const res = http.get(`${apiUrl}/status`);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(1); // Wait for 1 second between requests
}
