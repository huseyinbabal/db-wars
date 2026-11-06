// Shop rounds. MIX picks the share of each request; the rate climbs by STEP every HOLD.
//   k6 run -e BASE_URL=http://127.0.0.1:8000 -e MIX=status -e ORDERS=100000 -e START=200 -e STEP=200 -e STEPS=10 -e HOLD=20s k6/shop.js
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const ORDERS = parseInt(__ENV.ORDERS || '1000000');
const START = parseInt(__ENV.START || '200'), STEP = parseInt(__ENV.STEP || '200'), STEPS = parseInt(__ENV.STEPS || '20');
const HOLD = __ENV.HOLD || '30s';

// share of: new order, product by id, products of a category, order by id, customer's latest, views +1 (no index), status +1 (indexed)
const MIXES = {
  read:   [0, 0.4, 0.2, 0.2, 0.2, 0, 0],
  insert: [1, 0, 0, 0, 0, 0, 0],
  views:  [0, 0, 0, 0, 0, 1, 0],
  status: [0, 0, 0, 0, 0, 0, 1],
  shop5:  [0.05, 0.4, 0.2, 0.15, 0.2, 0, 0],
  shop20: [0.1, 0.3, 0.2, 0.15, 0.15, 0.05, 0.05],
};
const MIX = MIXES[__ENV.MIX || 'shop5'];
const PRODUCTS = 100000;

const stages = [];
for (let i = 0; i < STEPS; i++) {
  stages.push({ target: START + i * STEP, duration: '5s' });
  stages.push({ target: START + i * STEP, duration: HOLD });
}

export const options = {
  scenarios: {
    shop: { executor: 'ramping-arrival-rate', startRate: START, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 3000, stages },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_duration: [{ threshold: 'p(95)<2000', abortOnFail: true, delayAbortEval: '20s' }],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const rnd = (n) => 1 + Math.floor(Math.random() * n);
const json = { headers: { 'Content-Type': 'application/json' }, tags: { name: 'POST /orders' } };

export default function () {
  let r = Math.random(), k = 0;
  while (k < MIX.length - 1 && r >= MIX[k]) { r -= MIX[k]; k++; }
  let res, want = 200;
  switch (k) {
    case 0: {
      const a = rnd(PRODUCTS); let b = rnd(PRODUCTS); if (b === a) b = (a % PRODUCTS) + 1;
      res = http.post(`${BASE}/orders`, JSON.stringify({ customer_id: rnd(100000), items: [{ product_id: a, qty: 1 }, { product_id: b, qty: 2 }] }), json);
      want = 201; break;
    }
    case 1: res = http.get(`${BASE}/products/${rnd(PRODUCTS)}`, { tags: { name: 'GET /products/{id}' } }); break;
    case 2: res = http.get(`${BASE}/products?category=${rnd(100) - 1}&after=${rnd(PRODUCTS)}`, { tags: { name: 'GET /products' } }); break;
    case 3: res = http.get(`${BASE}/orders/${rnd(ORDERS)}`, { tags: { name: 'GET /orders/{id}' } }); break;
    case 4: res = http.get(`${BASE}/customers/${rnd(100000)}/orders`, { tags: { name: 'GET /customers/{id}/orders' } }); break;
    case 5: res = http.patch(`${BASE}/orders/${rnd(ORDERS)}/views`, null, { tags: { name: 'PATCH /orders/{id}/views' } }); want = 204; break;
    default: res = http.patch(`${BASE}/orders/${rnd(ORDERS)}/status`, null, { tags: { name: 'PATCH /orders/{id}/status' } }); want = 204;
  }
  check(res, { ok: (x) => x.status === want });
}
