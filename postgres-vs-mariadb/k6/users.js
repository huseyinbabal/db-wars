// Users arrive in levels. Each user sends a request, waits 50 to 150 ms, and sends the next one.
//   k6 run -e BASE_URL=http://10.0.0.2:8000 -e WRITES=0.05 -e USERS=100,200,400,800,1600 -e HOLD=170 k6/users.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8000';
const WRITES = parseFloat(__ENV.WRITES || '0.05');      // share of requests that create an order
const PRODUCTS = parseInt(__ENV.PRODUCTS || '100000');
const ORDERS = parseInt(__ENV.ORDERS || '1000000');
const USERS = (__ENV.USERS || '100,200,400,800,1600').split(',').map(Number);
const HOLD = parseInt(__ENV.HOLD || '170');

const stages = [];
for (const u of USERS) {
  stages.push({ target: u, duration: '10s' });          // new users log in
  stages.push({ target: u, duration: `${HOLD}s` });     // hold
}

export const options = {
  scenarios: { shop: { executor: 'ramping-vus', startVUs: 0, stages, gracefulRampDown: '5s', gracefulStop: '5s' } },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const rnd = (n) => 1 + Math.floor(Math.random() * n);
const post = { headers: { 'Content-Type': 'application/json' }, tags: { name: 'POST /orders' } };

export default function () {
  const r = Math.random();
  if (r < WRITES) {
    const a = rnd(PRODUCTS); let b = rnd(PRODUCTS); if (b === a) b = (a % PRODUCTS) + 1;
    const res = http.post(`${BASE}/orders`, JSON.stringify({ customer_id: rnd(100000), items: [{ product_id: a, qty: 1 }, { product_id: b, qty: 2 }] }), post);
    check(res, { 'order created': (x) => x.status === 201 });
  } else {
    const reads = (r - WRITES) / (1 - WRITES);
    let res;
    if (reads < 0.5) res = http.get(`${BASE}/products/${rnd(PRODUCTS)}`, { tags: { name: 'GET /products/{id}' } });
    else if (reads < 0.8) res = http.get(`${BASE}/products?category=${rnd(100) - 1}&after=${rnd(PRODUCTS)}`, { tags: { name: 'GET /products' } });
    else res = http.get(`${BASE}/orders/${rnd(ORDERS)}`, { tags: { name: 'GET /orders/{id}' } });
    check(res, { 'read ok': (x) => x.status === 200 });
  }
  sleep(0.05 + Math.random() * 0.1);
}
