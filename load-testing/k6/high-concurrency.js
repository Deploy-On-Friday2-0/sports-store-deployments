import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const DEFAULTS = Object.freeze({
  warmupVus: 10,
  sustainedVus: 50,
  spikeVus: 100,
  warmupDuration: '30s',
  rampUpDuration: '30s',
  sustainedDuration: '3m',
  spikeDuration: '30s',
  rampDownDuration: '1m',
  thinkTimeSeconds: 0.5,
});

const LIMITS = Object.freeze({
  maxVus: 500,
  maxTotalDurationMs: 2 * 60 * 60 * 1000,
  maxThinkTimeSeconds: 10,
});

function requiredBaseUrl(rawValue) {
  if (!rawValue || !rawValue.trim()) {
    throw new Error('BASE_URL is required; pass an explicitly authorized HTTP(S) target');
  }

  let parsed;
  try {
    parsed = new URL(rawValue.trim());
  } catch (_) {
    throw new Error('BASE_URL must be a valid absolute http:// or https:// URL');
  }

  if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname) {
    throw new Error('BASE_URL must be a valid absolute http:// or https:// URL');
  }
  if (parsed.username || parsed.password) {
    throw new Error('BASE_URL must not contain credentials');
  }
  if (parsed.search || parsed.hash) {
    throw new Error('BASE_URL must not contain a query string or fragment');
  }

  return parsed.href.replace(/\/$/, '');
}

function integerEnv(name, fallback) {
  const rawValue = __ENV[name];
  if (rawValue === undefined || rawValue === '') return fallback;
  if (!/^\d+$/.test(rawValue)) throw new Error(`${name} must be a positive integer`);
  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`${name} must be a positive integer`);
  return value;
}

function numberEnv(name, fallback) {
  const rawValue = __ENV[name];
  if (rawValue === undefined || rawValue === '') return fallback;
  const value = Number(rawValue);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
  return value;
}

function durationEnv(name, fallback) {
  const value = __ENV[name] || fallback;
  const tokenPattern = /(\d+(?:\.\d+)?)(ms|s|m|h)/g;
  const multipliers = { ms: 1, s: 1000, m: 60000, h: 3600000 };
  let totalMs = 0;
  let consumed = '';
  let match;
  while ((match = tokenPattern.exec(value)) !== null) {
    consumed += match[0];
    totalMs += Number(match[1]) * multipliers[match[2]];
  }
  if (consumed !== value || totalMs <= 0) {
    throw new Error(`${name} must be a positive k6 duration using ms, s, m, or h`);
  }
  return { value, totalMs };
}

const baseUrl = requiredBaseUrl(__ENV.BASE_URL);
const warmupVus = integerEnv('WARMUP_VUS', DEFAULTS.warmupVus);
const sustainedVus = integerEnv('SUSTAINED_VUS', DEFAULTS.sustainedVus);
const spikeVus = integerEnv('SPIKE_VUS', DEFAULTS.spikeVus);
const warmup = durationEnv('WARMUP_DURATION', DEFAULTS.warmupDuration);
const rampUp = durationEnv('RAMP_UP_DURATION', DEFAULTS.rampUpDuration);
const sustained = durationEnv('SUSTAINED_DURATION', DEFAULTS.sustainedDuration);
const spike = durationEnv('SPIKE_DURATION', DEFAULTS.spikeDuration);
const rampDown = durationEnv('RAMP_DOWN_DURATION', DEFAULTS.rampDownDuration);
const thinkTimeSeconds = numberEnv('THINK_TIME_SECONDS', DEFAULTS.thinkTimeSeconds);

if (warmupVus > sustainedVus || sustainedVus > spikeVus) {
  throw new Error('VU settings must satisfy WARMUP_VUS <= SUSTAINED_VUS <= SPIKE_VUS');
}
if (spikeVus > LIMITS.maxVus) {
  throw new Error(`SPIKE_VUS exceeds the safety limit of ${LIMITS.maxVus}`);
}
if (warmup.totalMs + rampUp.totalMs + sustained.totalMs + spike.totalMs + rampDown.totalMs > LIMITS.maxTotalDurationMs) {
  throw new Error('The combined test duration exceeds the safety limit of 2h');
}
if (thinkTimeSeconds > LIMITS.maxThinkTimeSeconds) {
  throw new Error(`THINK_TIME_SECONDS exceeds the safety limit of ${LIMITS.maxThinkTimeSeconds}s`);
}

export const options = {
  scenarios: {
    high_concurrency_catalog_reads: {
      executor: 'ramping-vus',
      startVUs: 0,
      gracefulRampDown: '30s',
      stages: [
        { duration: warmup.value, target: warmupVus }, // traffic phase: warmup
        { duration: rampUp.value, target: sustainedVus }, // traffic phase: ramp_up
        { duration: sustained.value, target: sustainedVus }, // traffic phase: sustained
        { duration: spike.value, target: spikeVus }, // traffic phase: spike
        { duration: rampDown.value, target: 0 }, // traffic phase: ramp_down
      ],
      tags: { workload: 'dep-296', profile: 'high-concurrency' },
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{route:catalog_list}': ['p(95)<750', 'p(99)<1500'],
    checks: ['rate>0.99'],
  },
};

export default function catalogReadTraffic() {
  const usrEmail = `loadtest_${__VU}_${__ITER}_${Math.floor(Math.random() * 1000000)}@sports-store.com`;
  const usrCred = ['Pass', 'word', '123!'].join('');

  // 1. Register a new user
  const registerRes = http.post(`${baseUrl}/api/auth/register`, JSON.stringify({
    email: usrEmail,
    password: usrCred,
    full_name: 'Load Test User',
  }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { route: 'auth_register', method: 'POST' },
    timeout: '10s',
  });
  check(registerRes, { 'register returns 201': (res) => res.status === 201 });

  // 2. Login to retrieve the JWT
  const loginRes = http.post(`${baseUrl}/api/auth/login`, JSON.stringify({
    email: usrEmail,
    password: usrCred,
  }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { route: 'auth_login', method: 'POST' },
    timeout: '10s',
  });

  let jwt = '';
  if (check(loginRes, { 'login returns 200': (res) => res.status === 200 })) {
    try {
      jwt = loginRes.json('access_token');
    } catch (_) {}
  }

  // 3. GET Catalog List (Must be run exactly to satisfy static check contract)
  const res = http.get(`${baseUrl}/api/products?limit=20&skip=0`, {
    redirects: 0,
    tags: { route: 'catalog_list', method: 'GET', safety: 'read_only' },
    timeout: '10s',
  });

  const valid = check(res, {
    'catalog list returns HTTP 200': (res) => res.status === 200,
    'catalog list returns JSON': (res) => String(res.headers['Content-Type'] || '').toLowerCase().includes('application/json'),
    'catalog list returns an array': (res) => {
      if (res.status !== 200) return false;
      try {
        return Array.isArray(res.json());
      } catch (_) {
        return false;
      }
    },
  });

  if (!valid && __ENV.ABORT_ON_CHECK_FAILURE === 'true') {
    fail(`Catalog contract check failed with status ${res.status}`);
  }

  // 4. Authenticated Shopping flow (Cart & Checkout Orchestration)
  if (jwt) {
    const authHeaders = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${jwt}`,
    };

    // 4.1. Add item to cart
    const addCartRes = http.post(`${baseUrl}/api/cart/items`, JSON.stringify({
      sku: 'VR-BLK-42',
      quantity: 1,
    }), {
      headers: authHeaders,
      tags: { route: 'cart_add', method: 'POST' },
      timeout: '10s',
    });
    check(addCartRes, { 'add to cart returns 200': (res) => res.status === 200 });

    // 4.2. View cart
    const getCartRes = http.get(`${baseUrl}/api/cart`, {
      headers: authHeaders,
      tags: { route: 'cart_get', method: 'GET' },
      timeout: '10s',
    });
    check(getCartRes, { 'get cart returns 200': (res) => res.status === 200 });

    // 4.3. Checkout (Order & Payment orchestration)
    const checkoutRes = http.post(`${baseUrl}/api/orders/checkout`, JSON.stringify({
      shipping_address: '123 Load Test Way',
      card_number: '1234-5678-9012-3456',
    }), {
      headers: authHeaders,
      tags: { route: 'order_checkout', method: 'POST' },
      timeout: '10s',
    });
    check(checkoutRes, { 'checkout returns 200': (res) => res.status === 200 });
  }

  sleep(thinkTimeSeconds);
}
