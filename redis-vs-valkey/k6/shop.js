// Redis vs Valkey: product page traffic, rate climbs in steps until the server can't keep up.
//   k6 run -e BASE_URL=http://10.0.0.6:8000 -e START=10000 -e STEP=10000 -e STEPS=10 -e HOLD=30s shop.js
// 60% product page (3 round trips), 20% trending (2), 20% add to cart (2)
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const PRODUCTS = parseInt(__ENV.PRODUCTS || '1000000'), USERS = 200000;
const START = parseInt(__ENV.START || '10000'), STEP = parseInt(__ENV.STEP || '10000'), STEPS = parseInt(__ENV.STEPS || '10');
const HOLD = __ENV.HOLD || '30s';

const stages = [];
for (let i = 0; i < STEPS; i++) {
  stages.push({ target: START + i * STEP, duration: '5s' });
  stages.push({ target: START + i * STEP, duration: HOLD });
}

export const options = {
  scenarios: { shop: { executor: 'ramping-arrival-rate', startRate: START, timeUnit: '1s', preAllocatedVUs: 3000, maxVUs: parseInt(__ENV.MAXVUS || '10000'), stages } },
  thresholds: { http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '20s' }] },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: true,
  // no `url` tag: every /products/{id} would become its own Prometheus series
  systemTags: ['status', 'method', 'name', 'scenario', 'expected_response', 'check'],
};

const rnd = (n) => 1 + Math.floor(Math.random() * n);

export default function () {
  const r = Math.random();
  let res, want = 200;
  if (r < 0.6) res = http.get(`${BASE}/products/${rnd(PRODUCTS)}`, { tags: { name: 'GET /products/{id}' } });
  else if (r < 0.8) res = http.get(`${BASE}/trending`, { tags: { name: 'GET /trending' } });
  else { res = http.post(`${BASE}/cart/${rnd(USERS)}?product=${rnd(PRODUCTS)}`, null, { tags: { name: 'POST /cart/{user}' } }); want = 201; }
  check(res, { ok: (x) => x.status === want });
}
