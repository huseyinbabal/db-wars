// Document rounds. MIX picks the share of each request; the rate climbs in steps like shop.js.
//   k6 run -e BASE_URL=http://127.0.0.1:8000 -e MIX=update -e ORDERS=100000 -e START=200 -e STEP=200 -e STEPS=10 -e HOLD=20s k6/doc.js
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const ORDERS = parseInt(__ENV.ORDERS || '1000000');
const START = parseInt(__ENV.START || '200'), STEP = parseInt(__ENV.STEP || '200'), STEPS = parseInt(__ENV.STEPS || '20');
const HOLD = __ENV.HOLD || '30s';

// share of: insert, get by id, customer's latest 10, orders with a product, status update, customer stats
const MIXES = {
  insert: [1, 0, 0, 0, 0, 0],
  read:   [0, 0.5, 0.3, 0.2, 0, 0],
  update: [0, 0, 0, 0, 1, 0],
  stats:  [0, 0, 0, 0, 0, 1],
  shop:   [0.1, 0.4, 0.2, 0.1, 0.15, 0.05],
};
const MIX = MIXES[__ENV.MIX || 'shop'];

const stages = [];
for (let i = 0; i < STEPS; i++) {
  stages.push({ target: START + i * STEP, duration: '5s' });
  stages.push({ target: START + i * STEP, duration: HOLD });
}

export const options = {
  scenarios: {
    doc: { executor: 'ramping-arrival-rate', startRate: START, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 3000, stages },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_duration: [{ threshold: 'p(95)<2000', abortOnFail: true, delayAbortEval: '20s' }],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const rnd = (n) => 1 + Math.floor(Math.random() * n);
const STATUS = ['paid', 'packed', 'shipped', 'delivered'];
const json = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  let r = Math.random(), k = 0;
  while (k < MIX.length - 1 && r >= MIX[k]) { r -= MIX[k]; k++; }
  let res;
  switch (k) {
    case 0:
      res = http.post(`${BASE}/orders`, null, { tags: { name: 'POST /orders' } });
      check(res, { 'insert ok': (x) => x.status === 201 });
      return;
    case 1: res = http.get(`${BASE}/orders/${rnd(ORDERS)}`, { tags: { name: 'GET /orders/{id}' } }); break;
    case 2: res = http.get(`${BASE}/customers/${rnd(100000)}/orders`, { tags: { name: 'GET /customers/{id}/orders' } }); break;
    case 3: res = http.get(`${BASE}/products/${rnd(100000)}/orders`, { tags: { name: 'GET /products/{id}/orders' } }); break;
    case 4:
      res = http.patch(`${BASE}/orders/${rnd(ORDERS)}/status`, JSON.stringify({ status: STATUS[rnd(4) - 1] }), Object.assign({ tags: { name: 'PATCH /orders/{id}/status' } }, json));
      check(res, { 'update ok': (x) => x.status === 204 });
      return;
    default: res = http.get(`${BASE}/customers/${rnd(100000)}/stats`, { tags: { name: 'GET /customers/{id}/stats' } });
  }
  check(res, { 'read ok': (x) => x.status === 200 });
}
