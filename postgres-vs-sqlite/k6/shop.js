// One script for every round. The request rate climbs in steps until the server gives up.
//   k6 run -e BASE_URL=http://127.0.0.1:8000 -e WRITES=0.05 -e START=100 -e STEP=100 -e STEPS=20 -e HOLD=30s k6/shop.js
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const WRITES = parseFloat(__ENV.WRITES || '0.05');      // share of requests that create an order
const PRODUCTS = parseInt(__ENV.PRODUCTS || '100000');
const ORDERS = parseInt(__ENV.ORDERS || '1000000');
const START = parseInt(__ENV.START || '100'), STEP = parseInt(__ENV.STEP || '100'), STEPS = parseInt(__ENV.STEPS || '20');
const HOLD = __ENV.HOLD || '30s';

const stages = [];
for (let i = 0; i < STEPS; i++) {
  stages.push({ target: START + i * STEP, duration: '5s' });   // climb
  stages.push({ target: START + i * STEP, duration: HOLD });   // hold
}

export const options = {
  scenarios: {
    shop: { executor: 'ramping-arrival-rate', startRate: START, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 3000, stages },
  },
  thresholds: {
    // stop only when the server is clearly gone; the breaking point is read per step from Prometheus (series.py)
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_duration: [{ threshold: 'p(95)<2000', abortOnFail: true, delayAbortEval: '20s' }],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const rnd = (n) => 1 + Math.floor(Math.random() * n);
const post = { headers: { 'Content-Type': 'application/json' }, tags: { name: 'POST /orders' } };

export default function () {
  const r = Math.random();
  let res;
  if (r < WRITES) {
    const a = rnd(PRODUCTS); let b = rnd(PRODUCTS); if (b === a) b = (a % PRODUCTS) + 1;
    res = http.post(`${BASE}/orders`, JSON.stringify({ customer_id: rnd(100000), items: [{ product_id: a, qty: 1 }, { product_id: b, qty: 2 }] }), post);
    check(res, { 'order created': (x) => x.status === 201 });
    return;
  }
  const reads = (r - WRITES) / (1 - WRITES);
  if (reads < 0.5) res = http.get(`${BASE}/products/${rnd(PRODUCTS)}`, { tags: { name: 'GET /products/{id}' } });
  else if (reads < 0.8) res = http.get(`${BASE}/products?category=${rnd(100) - 1}&after=${rnd(PRODUCTS)}`, { tags: { name: 'GET /products' } });
  else res = http.get(`${BASE}/orders/${rnd(ORDERS)}`, { tags: { name: 'GET /orders/{id}' } });
  check(res, { 'read ok': (x) => x.status === 200 });
}
