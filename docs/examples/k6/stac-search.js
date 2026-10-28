// k6 load test for a STAC API (issue #74). Copy to tests/load/script.js in
// the API repo and call load-test.yml with target-url set to the staging
// root. Thresholds make it a gate: p95 under 800 ms, under 1 % failed
// requests, every check passing.
//
// Local run: BASE_URL=https://stac.example.com k6 run --vus 10 --duration 1m stac-search.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  thresholds: {
    http_req_duration: ['p(95)<800'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

const BASE_URL = __ENV.BASE_URL;
// Vancouver area; replace with a bbox that the catalogue actually covers.
const BBOX = [-123.3, 49.1, -122.9, 49.4];

export default function () {
  const collections = http.get(`${BASE_URL}/collections`, { tags: { name: 'collections' } });
  check(collections, {
    'collections 200': (r) => r.status === 200,
    'collections lists at least one': (r) => (r.json('collections') || []).length > 0,
  });

  const search = http.post(
    `${BASE_URL}/search`,
    JSON.stringify({ bbox: BBOX, limit: 10 }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'search' } },
  );
  check(search, {
    'search 200': (r) => r.status === 200,
    'search returns a FeatureCollection': (r) => r.json('type') === 'FeatureCollection',
  });

  sleep(1);
}
