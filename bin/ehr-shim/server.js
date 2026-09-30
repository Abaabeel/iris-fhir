#!/usr/bin/env node
'use strict';

/*
 * ehr-shim — an InterSystems IRIS for Health FHIR R4 server fronted on port
 * 8080 in the place of the mock test-ehr. Replicates test-ehr's SMART-launch
 * and OAuth-bridge contract exactly (see repos/test-ehr/.../authproxy/
 * AuthProxy.java and PKCEUtil.java), while proxying every other FHIR request
 * to IRIS with a freshly minted bearer token.
 *
 * Surface (all of test-ehr's, plus the FHIR pass-through):
 *   POST /fhir/r4/_services/smart/Launch             -> { "launch_id": <uuid> }
 *   GET  /fhir/r4/.well-known/smart-configuration    -> SMART discovery
 *   GET  /fhir/r4/.well-known/openid-configuration   -> OIDC discovery (fallback)
 *   GET  /fhir/r4/auth                               -> 302 to Keycloak authorize
 *   GET  /test-ehr/_auth/{launch}                    -> associate code w/ launch,
 *                                                        302 back to the SMART app
 *   POST /fhir/r4/token                              -> Keycloak token exchange,
 *                                                        then launch context injected
 *   ALL  /fhir/r4/**                                 -> proxied to IRIS with a token
 *
 * The /test-ehr/_auth/{launch} path is deliberate: the Keycloak realm's
 * app-login client allows redirect URIs under http://localhost:8080/test-ehr/*
 * only, so the wrapped redirect keeps that path root while the FHIR surface
 * lives under /fhir/r4. Zero realm changes.
 *
 * Env (all optional; defaults match the stack in bin/env.sh):
 *   SHIM_PORT           listen port (8080)
 *   IRIS_FHIR_BASE      https://10.0.3.108:52774/fhir/r4
 *   IRIS_FHIR_CERT      path to the IRIS TLS cert (bundled iris-fhir.crt)
 *   IRIS_OAUTH_TOKEN    https://10.0.3.108:52774/oauth2/token
 *   IRIS_OAUTH_CLIENT_ID / IRIS_OAUTH_CLIENT_SECRET  (confidential client)
 *   IRIS_OAUTH_SCOPES   user/*.write user/*.rs
 *   KC_AUTHORIZE / KC_TOKEN   Keycloak endpoints (localhost:8180 realm
 *                             BurdenReduction — same defaults as test-ehr)
 */

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const CFG = {
  port: parseInt(process.env.SHIM_PORT || '8080', 10),
  irisBase: process.env.IRIS_FHIR_BASE || 'https://10.0.3.108:52774/fhir/r4',
  irisCert: process.env.IRIS_FHIR_CERT || path.join(__dirname, 'iris-fhir.crt'),
  irisTokenUrl: process.env.IRIS_OAUTH_TOKEN || 'https://10.0.3.108:52774/oauth2/token',
  irisClientId: process.env.IRIS_OAUTH_CLIENT_ID,
  irisClientSecret: process.env.IRIS_OAUTH_CLIENT_SECRET,
  irisScopes: process.env.IRIS_OAUTH_SCOPES || 'user/*.write user/*.rs',
  kcAuthorize: process.env.KC_AUTHORIZE ||
    'http://localhost:8180/realms/BurdenReduction/protocol/openid-connect/auth',
  kcToken: process.env.KC_TOKEN ||
    'http://localhost:8180/realms/BurdenReduction/protocol/openid-connect/token',
};

if (!CFG.irisClientId || !CFG.irisClientSecret) {
  console.error('ehr-shim: IRIS_OAUTH_CLIENT_ID / IRIS_OAUTH_CLIENT_SECRET are required');
  process.exit(1);
}

let caCert = null;
try { caCert = fs.readFileSync(CFG.irisCert); }
catch (e) { console.error('ehr-shim: cannot read IRIS cert ' + CFG.irisCert + ': ' + e.message); process.exit(1); }

// ---------------------------------------------------------------------------
// launch-context store (test-ehr's PayloadDAO is an in-memory cache too)
// ---------------------------------------------------------------------------
const launches = new Map();   // launchId -> payload
const byCode = new Map();     // oauth code -> launchId

function makePayload(launchId, launchUrl, params) {
  params = params || {};
  const str = (v) => (v === null || v === undefined ? null : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
  return {
    launchId,
    launchUrl: launchUrl || '',
    patient: str(params.patient),
    appContext: str(params.appContext),
    fhirContext: str(params.fhirContext),
    codeVerifier: null,
    codeChallenge: null,
    redirectUri: null,
    code: null,
  };
}

// ---------------------------------------------------------------------------
// PKCE (RFC 7636) — identical to test-ehr's PKCEUtil
// ---------------------------------------------------------------------------
const VERIFIER_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
function genVerifier() {
  const bytes = crypto.randomBytes(64);
  let out = '';
  for (let i = 0; i < 64; i++) out += VERIFIER_ALPHABET[bytes[i] % VERIFIER_ALPHABET.length];
  return out;
}
function genChallenge(verifier) {
  return crypto.createHash('sha256').update(verifier).digest('base64url');
}

// ---------------------------------------------------------------------------
// IRIS token minting / caching (tokens live ~300 s)
// ---------------------------------------------------------------------------
let tokenCache = { token: null, exp: 0 };   // exp is a unix epoch seconds

function jwtExpiry(token) {
  try {
    const p = token.split('.')[1];
    const pad = p.length % 4 === 3 ? '=' : (p.length % 4 === 2 ? '==' : '');
    const json = Buffer.from(p.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64').toString('utf8');
    return JSON.parse(json).exp || 0;
  } catch (e) { return 0; }
}

function postForm(url, fields, agent) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const body = new URLSearchParams(fields).toString();
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request({
      method: 'POST',
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(body),
      },
      ...(lib === https ? { ca: caCert } : {}),
      agent,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch (e) { /* not json */ }
        resolve({ status: res.statusCode, json, text });
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

async function getToken() {
  const now = Math.floor(Date.now() / 1000);
  if (tokenCache.token && tokenCache.exp - 20 > now) return tokenCache.token;
  const res = await postForm(CFG.irisTokenUrl, {
    grant_type: 'client_credentials',
    client_id: CFG.irisClientId,
    client_secret: CFG.irisClientSecret,
    scope: CFG.irisScopes,
    aud: CFG.irisBase,
  });
  if (res.status !== 200 || !res.json || !res.json.access_token) {
    throw new Error('IRIS token mint failed (' + res.status + '): ' + (res.text || '').slice(0, 300));
  }
  const token = res.json.access_token;
  const exp = jwtExpiry(token);
  tokenCache = { token, exp: exp || now + 240 };
  return token;
}

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailers', 'transfer-encoding', 'upgrade', 'host', 'authorization',
  'content-length',
]);

function cors(res, req) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers',
    req.headers['access-control-request-headers'] || 'Content-Type,Authorization,Accept');
  res.setHeader('Access-Control-Expose-Headers', 'Location,Content-Location,ETag');
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Length', Buffer.byteLength(body));
  res.end(body);
}

function readBody(req, limit) {
  limit = limit || 20 * 1024 * 1024;
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function oo(code, diagnostics) {
  return { resourceType: 'OperationOutcome', issue: [{ severity: 'error', code: code || 'exception', diagnostics }] };
}

// ---------------------------------------------------------------------------
// SMART / OAuth handlers (replicating AuthProxy.java)
// ---------------------------------------------------------------------------
function handleLaunch(req, res) {
  readBody(req).then((text) => {
    let payload;
    try { payload = JSON.parse(text); } catch (e) {
      sendJson(res, 400, oo('invalid', 'Launch body must be JSON'));
      return;
    }
    console.log('Launch body: launchUrl=' + (payload.launchUrl || '') +
      ' params=' + JSON.stringify(payload.parameters || {}));
    const launchId = crypto.randomUUID();
    const entry = makePayload(launchId, payload.launchUrl, payload.parameters || {});
    entry.codeVerifier = genVerifier();
    entry.codeChallenge = genChallenge(entry.codeVerifier);
    launches.set(launchId, entry);
    cors(res, req);
    sendJson(res, 200, { launch_id: launchId });
  }).catch((e) => {
    cors(res, req);
    sendJson(res, 413, oo('too-large', String(e && e.message)));
  });
}

function discovery(req, res) {
  const base = 'http://' + req.headers.host + '/fhir/r4';
  cors(res, req);
  sendJson(res, 200, {
    issuer: base,
    authorization_endpoint: base + '/auth',
    token_endpoint: base + '/token',
    response_types_supported: ['code'],
    scopes_supported: [
      'launch', 'launch/patient', 'openid', 'fhirUser', 'profile',
      'user/Observation.read', 'user/Patient.read', 'user/Coverage.read',
      'user/Condition.read', 'user/Practitioner.read', 'user/Encounter.read',
      'user/MedicationRequest.read', 'user/QuestionnaireResponse.read',
      'user/Questionnaire.read', 'patient/Observation.read', 'patient/Patient.read',
      'patient/Coverage.read', 'patient/Condition.read', 'patient/Encounter.read',
      'patient/MedicationRequest.read', 'patient/QuestionnaireResponse.read',
      'patient/DeviceRequest.read',
    ],
    capabilities: [
      'launch-standalone', 'launch-ehr', 'client-public', 'sso-openid-connect',
      'context-standalone-patient', 'context-ehr-patient', 'context-patient',
      'context-style', 'context-banner', 'permission-patient', 'permission-offline',
    ],
  });
}

function handleAuth(req, res) {
  const u = new URL(req.url, 'http://localhost');
  const q = u.searchParams;
  const host = req.headers.host;

  const launchId = q.get('launch');
  let entry;
  if (launchId) {
    entry = launches.get(launchId);
    if (!entry) {
      cors(res, req);
      sendJson(res, 400, oo('invalid', 'Unknown launch id ' + launchId));
      return;
    }
    entry.redirectUri = 'http://' + host + '/test-ehr/_auth/' + encodeURIComponent(launchId) +
      '?redirect_uri=' + encodeURIComponent(q.get('redirect_uri') || '');
  } else {
    // standalone launch (no launch id yet) — mirror AuthProxy._standaloneRedirect
    const id = 'standalone' + crypto.randomUUID();
    entry = makePayload(id, '', {});
    entry.codeVerifier = genVerifier();
    entry.codeChallenge = genChallenge(entry.codeVerifier);
    launches.set(id, entry);
    entry.redirectUri = 'http://' + host + '/test-ehr/_auth/' + id +
      '?redirect_uri=' + encodeURIComponent(q.get('redirect_uri') || '');
  }

  const out = new URLSearchParams(q);
  out.set('redirect_uri', entry.redirectUri);
  if (!out.has('code_challenge')) {
    entry.codeVerifier = genVerifier();
    entry.codeChallenge = genChallenge(entry.codeVerifier);
    out.set('code_challenge', entry.codeChallenge);
    out.set('code_challenge_method', 'S256');
  }

  cors(res, req);
  res.statusCode = 302;
  res.setHeader('Location', CFG.kcAuthorize + '?' + out.toString());
  res.end();
}

function handleAuthSync(req, res, launchId) {
  const u = new URL(req.url, 'http://localhost');
  const q = u.searchParams;
  const code = q.get('code') || '';
  const state = q.get('state') || '';
  const back = q.get('redirect_uri') || '';

  const entry = launches.get(launchId);
  if (entry) {
    entry.code = code;
    if (code) byCode.set(code, launchId);
  }

  const target = new URL(back, 'http://localhost');
  target.searchParams.set('code', code);
  if (state) target.searchParams.set('state', state);

  cors(res, req);
  res.statusCode = 302;
  res.setHeader('Location', target.toString());
  res.end();
}

async function handleToken(req, res) {
  let text;
  try { text = await readBody(req); } catch (e) {
    cors(res, req);
    sendJson(res, 413, oo('too-large', 'body too large'));
    return;
  }
  const body = new URLSearchParams(text);
  const code = body.get('code') || '';
  const launchId = byCode.get(code);
  const entry = launchId ? launches.get(launchId) : null;
  if (!entry) {
    cors(res, req);
    sendJson(res, 400, oo('invalid_grant', 'no launch context for this code'));
    return;
  }
  if (entry.redirectUri) body.set('redirect_uri', entry.redirectUri);
  if (entry.codeVerifier) body.set('code_verifier', entry.codeVerifier);

  try {
    const kc = await postForm(CFG.kcToken, body); // Keycloak is plain http here
    if (kc.status !== 200 || !kc.json) {
      cors(res, req);
      sendJson(res, kc.status || 400, kc.json || oo('invalid_grant', kc.text.slice(0, 300)));
      return;
    }
    if (entry.patient) kc.json.patient = entry.patient;
    if (entry.appContext) kc.json.appContext = entry.appContext;
    if (entry.fhirContext) kc.json.fhirContext = entry.fhirContext;
    cors(res, req);
    sendJson(res, 200, kc.json);
  } catch (e) {
    console.error('ehr-shim: token forward failed: ' + e.message);
    cors(res, req);
    sendJson(res, 502, oo('exception', 'Keycloak token endpoint unreachable: ' + e.message));
  }
}

// ---------------------------------------------------------------------------
// FHIR pass-through to IRIS
// ---------------------------------------------------------------------------
async function handleProxy(req, res) {
  const u = new URL(req.url, 'http://localhost');
  let token;
  try {
    token = await getToken();
  } catch (e) {
    console.error('ehr-shim: ' + e.message);
    cors(res, req);
    sendJson(res, 502, oo('exception', e.message));
    return;
  }

  const iris = new URL(CFG.irisBase);
  const headers = { authorization: 'Bearer ' + token };
  for (const [k, v] of Object.entries(req.headers)) {
    if (!HOP_BY_HOP.has(k.toLowerCase()) && v !== undefined) headers[k] = v;
  }

  const fwd = https.request({
    method: req.method,
    hostname: iris.hostname,
    port: iris.port || 443,
    path: u.pathname + u.search,
    headers,
    ca: caCert,
  }, (up) => {
    cors(res, req);
    res.statusCode = up.statusCode;
    for (const [k, v] of Object.entries(up.headers)) {
      if (!HOP_BY_HOP.has(k.toLowerCase()) && v !== undefined) res.setHeader(k, v);
    }
    up.pipe(res);
  });

  fwd.on('error', (e) => {
    console.error('ehr-shim: IRIS proxy failed: ' + e.message);
    if (!res.headersSent) {
      cors(res, req);
      sendJson(res, 502, oo('exception', 'IRIS unreachable: ' + e.message));
    } else {
      res.destroy();
    }
  });

  req.pipe(fwd);
}

// ---------------------------------------------------------------------------
// server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  const p = u.pathname;
  const t0 = Date.now();
  res.on('finish', () => {
    console.log(req.method + ' ' + p + (u.search || '') + ' -> ' + res.statusCode +
      ' (' + (Date.now() - t0) + 'ms)');
  });

  if (req.method === 'OPTIONS') {
    cors(res, req);
    res.statusCode = 204;
    res.end();
    return;
  }

  // SMART surface (launch / discovery / auth / auth-sync / token)
  if (req.method === 'POST' &&
      (p === '/fhir/r4/_services/smart/Launch' || p === '/test-ehr/_services/smart/Launch')) {
    handleLaunch(req, res);
    return;
  }
  if (req.method === 'GET' && p === '/fhir/r4/.well-known/smart-configuration') {
    discovery(req, res);
    return;
  }
  if (req.method === 'GET' && p === '/fhir/r4/.well-known/openid-configuration') {
    discovery(req, res);
    return;
  }
  if (req.method === 'GET' && (p === '/fhir/r4/auth' || p === '/test-ehr/auth')) {
    handleAuth(req, res);
    return;
  }
  const authSyncMatch = p.match(/^\/(?:test-ehr|fhir\/r4)\/_auth\/([^/]+)$/);
  if (req.method === 'GET' && authSyncMatch) {
    handleAuthSync(req, res, authSyncMatch[1]);
    return;
  }
  if (req.method === 'POST' && (p === '/fhir/r4/token' || p === '/test-ehr/token')) {
    handleToken(req, res);
    return;
  }

  // everything else under the FHIR base is a pass-through
  if (p.startsWith('/fhir/r4') || p.startsWith('/test-ehr/r4')) {
    handleProxy(req, res);
    return;
  }

  cors(res, req);
  sendJson(res, 404, oo('not-found', 'ehr-shim: no route for ' + req.method + ' ' + p));
});

server.listen(CFG.port, '0.0.0.0', () => {
  console.log('ehr-shim listening on :' + CFG.port + ' -> ' + CFG.irisBase);
});