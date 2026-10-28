// Smoke script used by the k6 composite's own CI run and tests. Hits the root
// of BASE_URL; P95_MS tightens the latency threshold so a failing run can be
// exercised without a slow server.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  thresholds: {
    http_req_duration: [`p(95)<${__ENV.P95_MS || 2000}`],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

const BASE_URL = __ENV.BASE_URL;

export default function () {
  const res = http.get(`${BASE_URL}/`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
