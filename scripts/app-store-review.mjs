import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const apiOrigin = 'https://api.appstoreconnect.apple.com';
const bundleID = 'com.aegorsuch.weartak';
const editableStates = new Set([
  'PREPARE_FOR_SUBMISSION', 'READY_FOR_REVIEW', 'REJECTED',
  'DEVELOPER_REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY',
]);
const submittedStates = new Set(['WAITING_FOR_REVIEW', 'IN_REVIEW']);
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

function requireValue(value, name) {
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function releaseIdentity(tag, build) {
  const match = /^v(\d+\.\d+\.\d+(?:\.\d+)?)(?:-testflight\.[1-9]\d*)?$/.exec(tag ?? '');
  if (!match || !/^[1-9]\d*$/.test(build ?? '')) {
    throw new Error('Expected a vMAJOR.MINOR.PATCH[.BUILD][-testflight.N] tag and positive numeric pipeline IID.');
  }
  return { version: match[1], build };
}

export function submissionConfiguration(env, read = readFileSync) {
  const identity = releaseIdentity(env.CI_COMMIT_TAG, env.CI_PIPELINE_IID);
  if (env.CI_JOB_MANUAL !== 'true' || env.CI_COMMIT_REF_PROTECTED !== 'true') {
    throw new Error('App Review submission requires a manually played job on a protected version tag.');
  }
  const confirmation = `${identity.version} (${identity.build})`;
  if (env.APP_STORE_SUBMISSION_CONFIRM !== confirmation) {
    throw new Error(`No submission authorized. Set APP_STORE_SUBMISSION_CONFIRM to "${confirmation}" on this manual job only.`);
  }
  const releaseType = env.APP_STORE_RELEASE_TYPE ?? 'MANUAL';
  if (!['MANUAL', 'AFTER_APPROVAL'].includes(releaseType)) {
    throw new Error('APP_STORE_RELEASE_TYPE must be MANUAL (default) or AFTER_APPROVAL.');
  }
  if (env.APP_STORE_CREATE_VERSION !== undefined && !['true', 'false'].includes(env.APP_STORE_CREATE_VERSION)) {
    throw new Error('APP_STORE_CREATE_VERSION must be true or false (default). Existing versions are reused without a version bump.');
  }
  if (Boolean(env.APP_STORE_WHATS_NEW) === Boolean(env.APP_STORE_WHATS_NEW_FILE)) {
    throw new Error('Set exactly one of APP_STORE_WHATS_NEW or APP_STORE_WHATS_NEW_FILE.');
  }
  const whatsNew = (env.APP_STORE_WHATS_NEW ?? read(env.APP_STORE_WHATS_NEW_FILE, 'utf8')).trim();
  if (!whatsNew || [...whatsNew].length > 4_000 || whatsNew.includes('\0')) {
    throw new Error("What's New must contain 1-4,000 characters without NUL.");
  }
  const locale = env.APP_STORE_WHATS_NEW_LOCALE;
  if (locale && !/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(locale)) {
    throw new Error('APP_STORE_WHATS_NEW_LOCALE is not a valid App Store locale.');
  }
  const timeout = env.APP_STORE_PROCESSING_TIMEOUT_SECONDS ?? '1800';
  if (!/^\d+$/.test(timeout) || Number(timeout) < 30 || Number(timeout) > 7_200) {
    throw new Error('APP_STORE_PROCESSING_TIMEOUT_SECONDS must be between 30 and 7200.');
  }
  const receipt = JSON.parse(read(requireValue(env.APP_STORE_UPLOAD_RECEIPT, 'APP_STORE_UPLOAD_RECEIPT'), 'utf8'));
  if (receipt.tag !== env.CI_COMMIT_TAG || receipt.version !== identity.version ||
      receipt.build !== identity.build || receipt.sha !== requireValue(env.CI_COMMIT_SHA, 'CI_COMMIT_SHA') ||
      receipt.pipelineID !== requireValue(env.CI_PIPELINE_ID, 'CI_PIPELINE_ID') || receipt.uploadAccepted !== true) {
    throw new Error('Upload receipt does not match this tag, build, commit and pipeline, or upload did not succeed.');
  }
  return { ...identity, releaseType, whatsNew, locale, processingTimeoutSeconds: Number(timeout),
    createVersion: env.APP_STORE_CREATE_VERSION === 'true' };
}

export class AppStoreClient {
  constructor({ privateKey, keyID, issuerID, fetchImpl = fetch, wait = sleep, now = Date.now }) {
    if (!/^[A-Za-z0-9]+$/.test(keyID ?? '') ||
        !/^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(issuerID ?? '')) {
      throw new Error('App Store Connect API key ID or issuer ID is invalid.');
    }
    this.privateKey = createPrivateKey(requireValue(privateKey, 'App Store Connect private key'));
    if (this.privateKey.asymmetricKeyType !== 'ec' ||
        this.privateKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
      throw new Error('App Store Connect requires an ES256/P-256 private key.');
    }
    this.keyID = keyID;
    this.issuerID = issuerID;
    this.fetch = fetchImpl;
    this.wait = wait;
    this.now = now;
  }

  token() {
    const issuedAt = Math.floor(this.now() / 1000);
    const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: this.keyID, typ: 'JWT' })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({
      iss: this.issuerID, iat: issuedAt, exp: issuedAt + 600, aud: 'appstoreconnect-v1',
    })).toString('base64url');
    const message = `${header}.${claims}`;
    const signature = sign('sha256', Buffer.from(message),
      { key: this.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    return `${message}.${signature}`;
  }

  async request(method, path, body) {
    const url = new URL(path, apiOrigin);
    if (url.origin !== apiOrigin || !url.pathname.startsWith('/v1/')) {
      throw new Error('Refusing an App Store API URL outside the expected HTTPS origin and /v1 path.');
    }
    for (let attempt = 0; ; attempt++) {
      let response;
      try {
        response = await this.fetch(url, {
          method, redirect: 'error', signal: AbortSignal.timeout(30_000),
          headers: { Authorization: `Bearer ${this.token()}`, 'Content-Type': 'application/json' },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        });
      } catch {
        throw new Error(`App Store API ${method} ${url.pathname} transport failed. ${
          method === 'GET' ? 'Retry the read.' : 'The write outcome is unknown; inspect App Store Connect before retrying.'
        }`);
      }
      if (method === 'GET' && attempt < 2 && (response.status === 429 || response.status >= 500)) {
        const retry = Number(response.headers.get('retry-after'));
        await this.wait(Number.isFinite(retry) && retry > 0 ? Math.min(retry, 60) * 1000 : 2_000 * (attempt + 1));
        continue;
      }
      if (response.status === 204) return {};
      let result;
      try { result = await response.json(); }
      catch { throw new Error(`App Store API ${method} ${url.pathname} returned HTTP ${response.status} without JSON; inspect the operation before retrying.`); }
      if (!response.ok) {
        if (response.status === 403) {
          throw new Error(`App Store API access denied (403) for ${method} ${url.pathname}. The API key needs App Manager or Admin rights and access to WearTAK; upload-only/Developer permission is insufficient for App Review.`);
        }
        if (response.status === 401) {
          throw new Error('App Store API authentication failed (401). Check the API key, issuer, private key and runner clock.');
        }
        const detail = (result.errors ?? []).map(error => `${error.code}: ${error.detail ?? error.title}`).join('; ').slice(0, 1500);
        throw new Error(`App Store API ${method} ${url.pathname} failed (HTTP ${response.status}): ${detail || 'No error detail'}`);
      }
      return result;
    }
  }

  async list(path, query = {}) {
    let next = `${path}?${new URLSearchParams({ limit: '200', ...query })}`;
    const data = [], included = [];
    const visited = new Set();
    while (next) {
      if (visited.has(next) || visited.size >= 50) throw new Error('App Store API pagination did not terminate within 50 pages.');
      visited.add(next);
      const page = await this.request('GET', next);
      if (!Array.isArray(page.data)) throw new Error('App Store API list response has no resource array.');
      data.push(...page.data);
      included.push(...(page.included ?? []));
      next = page.links?.next;
    }
    return { data, included };
  }
}

function resource(type, attributes, relationships, id) {
  return { data: { type, ...(id ? { id } : {}), ...(attributes ? { attributes } : {}),
    ...(relationships ? { relationships } : {}) } };
}

function relation(type, id) { return { data: { type, id } }; }

export async function findApp(api) {
  const { data } = await api.list('/v1/apps', { 'filter[bundleId]': bundleID });
  if (data.length !== 1 || data[0].attributes?.bundleId !== bundleID) {
    throw new Error('Expected exactly one accessible WearTAK app for com.aegorsuch.weartak.');
  }
  return data[0];
}

async function findBuild(api, appID, version, build) {
  const result = await api.list('/v1/builds', {
    'filter[app]': appID, 'filter[version]': build,
    'filter[preReleaseVersion.version]': version, 'filter[preReleaseVersion.platform]': 'IOS',
    include: 'preReleaseVersion,buildBetaDetail',
  });
  if (result.data.length > 1) throw new Error('More than one build matches the exact marketing version and build number.');
  const match = result.data[0];
  if (!match) return undefined;
  const preReleaseID = match.relationships?.preReleaseVersion?.data?.id;
  const preRelease = result.included.find(item => item.type === 'preReleaseVersions' && item.id === preReleaseID);
  if (match.attributes?.version !== build || preRelease?.attributes?.version !== version ||
      preRelease?.attributes?.platform !== 'IOS') {
    throw new Error('App Store API build identity does not match the requested iOS marketing version and build.');
  }
  return { build: match, beta: result.included.find(item =>
    item.type === 'buildBetaDetails' && item.id === match.relationships?.buildBetaDetail?.data?.id) };
}

export async function status(api, version, build) {
  releaseIdentity(`v${version}`, build);
  const app = await findApp(api);
  const match = await findBuild(api, app.id, version, build);
  const { data: versions } = await api.list(`/v1/apps/${app.id}/appStoreVersions`, { 'filter[platform]': 'IOS' });
  return {
    appID: app.id, version, build,
    processingState: match?.build.attributes.processingState ?? 'NOT_FOUND',
    expired: match?.build.attributes.expired ?? null,
    internalBuildState: match?.beta?.attributes.internalBuildState ?? null,
    externalBuildState: match?.beta?.attributes.externalBuildState ?? null,
    publicVersions: versions.filter(item => ['READY_FOR_SALE', 'READY_FOR_DISTRIBUTION'].includes(
      item.attributes.appVersionState ?? item.attributes.appStoreState)).map(item => item.attributes.versionString),
    prepareForSubmissionVersions: versions.filter(item =>
      (item.attributes.appVersionState ?? item.attributes.appStoreState) === 'PREPARE_FOR_SUBMISSION')
      .map(item => ({ id: item.id, version: item.attributes.versionString, releaseType: item.attributes.releaseType })),
    appStoreVersions: versions.filter(item => item.attributes.versionString === version).map(item => ({
      id: item.id, state: item.attributes.appVersionState ?? item.attributes.appStoreState,
      releaseType: item.attributes.releaseType,
    })),
  };
}

async function waitForBuild(api, appID, config, { wait, now, log }) {
  const deadline = now() + config.processingTimeoutSeconds * 1000;
  while (true) {
    const match = await findBuild(api, appID, config.version, config.build);
    const state = match?.build.attributes.processingState ?? 'NOT_FOUND';
    log(`Build ${config.version} (${config.build}): ${state}`);
    if (state === 'VALID') {
      if (match.build.attributes.expired !== false) throw new Error('The uploaded build is expired or its expiry status is unknown.');
      if (match.build.attributes.buildAudienceType === 'INTERNAL_ONLY') throw new Error('This internal-only TestFlight build is not eligible for App Store review.');
      return match.build;
    }
    if (['FAILED', 'INVALID'].includes(state)) throw new Error(`Apple build processing ended in ${state}; no App Review changes were made.`);
    if (!['PROCESSING', 'NOT_FOUND'].includes(state)) throw new Error(`Unexpected Apple build processing state: ${state}`);
    if (now() >= deadline) throw new Error('Timed out waiting for Apple build processing; no App Review changes were made.');
    await wait(Math.min(30_000, deadline - now()));
  }
}

export async function submit(api, config, { wait = sleep, now = Date.now, log = console.log } = {}) {
  const app = await findApp(api);
  const build = await waitForBuild(api, app.id, config, { wait, now, log });
  const versions = await api.list(`/v1/apps/${app.id}/appStoreVersions`, {
    'filter[versionString]': config.version, 'filter[platform]': 'IOS',
  });
  if (versions.data.length > 1) throw new Error('More than one App Store version matches this release.');
  let version = versions.data[0];
  if (!version && !config.createVersion) {
    throw new Error(`No existing App Store version ${config.version}. No version was created. Create it explicitly in App Store Connect or authorize APP_STORE_CREATE_VERSION=true on this manual job.`);
  }
  if (version) {
    if (version.attributes.versionString !== config.version || version.attributes.platform !== 'IOS') {
      throw new Error('App Store version identity does not match the requested iOS marketing version; no changes made.');
    }
    const state = version.attributes.appVersionState ?? version.attributes.appStoreState;
    if (submittedStates.has(state)) {
      const attached = await api.request('GET', `/v1/appStoreVersions/${version.id}/relationships/build`);
      if (attached.data?.id !== build.id || version.attributes.releaseType !== config.releaseType) {
        throw new Error('This version is already in review with a different build or release mode; refusing to change it.');
      }
      log(`Already submitted: ${config.version} (${config.build}), ${state}. No changes made.`);
      return { versionID: version.id, state, alreadySubmitted: true };
    }
    if (!editableStates.has(state)) throw new Error(`App Store version ${config.version} is not editable (${state}); no changes made.`);
  }
  const reviews = await api.list('/v1/reviewSubmissions', { 'filter[app]': app.id, 'filter[platform]': 'IOS' });
  const active = reviews.data.filter(item => item.attributes.state !== 'COMPLETE');
  if (active.length > 1 || active.some(item => item.attributes.state !== 'READY_FOR_REVIEW')) {
    throw new Error('Another review submission is active or unresolved. Resolve it in App Store Connect; no changes made.');
  }
  let review = active[0];
  let items = [];
  if (review) {
    items = (await api.list(`/v1/reviewSubmissions/${review.id}/items`, { include: 'appStoreVersion' })).data;
    if (items.some(item => !version || item.relationships?.appStoreVersion?.data?.id !== version.id) || items.length > 1) {
      throw new Error('The draft review contains unrelated items; refusing to submit them or modify this release.');
    }
  }
  const locale = config.locale ?? app.attributes.primaryLocale;
  requireValue(locale, "What's New locale (APP_STORE_WHATS_NEW_LOCALE or app primary locale)");
  if (!version) {
    ({ data: version } = await api.request('POST', '/v1/appStoreVersions',
      resource('appStoreVersions', { platform: 'IOS', versionString: config.version, releaseType: config.releaseType },
        { app: relation('apps', app.id), build: relation('builds', build.id) })));
  } else {
    await api.request('PATCH', `/v1/appStoreVersions/${version.id}`,
      resource('appStoreVersions', { releaseType: config.releaseType }, { build: relation('builds', build.id) }, version.id));
  }
  if (!version?.id) throw new Error('App Store version write returned no version ID; inspect App Store Connect before retrying.');
  const localizations = await api.list(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  const matches = localizations.data.filter(item => item.attributes.locale === locale);
  if (matches.length > 1) throw new Error(`Duplicate App Store localizations for ${locale}.`);
  if (matches.length) {
    await api.request('PATCH', `/v1/appStoreVersionLocalizations/${matches[0].id}`,
      resource('appStoreVersionLocalizations', { whatsNew: config.whatsNew }, undefined, matches[0].id));
  } else {
    await api.request('POST', '/v1/appStoreVersionLocalizations',
      resource('appStoreVersionLocalizations', { locale, whatsNew: config.whatsNew },
        { appStoreVersion: relation('appStoreVersions', version.id) }));
  }
  if (!review) {
    ({ data: review } = await api.request('POST', '/v1/reviewSubmissions',
      resource('reviewSubmissions', { platform: 'IOS' }, { app: relation('apps', app.id) })));
  }
  if (!review?.id) throw new Error('Review draft creation returned no ID; inspect App Store Connect before retrying.');
  if (!items.length) {
    await api.request('POST', '/v1/reviewSubmissionItems',
      resource('reviewSubmissionItems', undefined, {
        reviewSubmission: relation('reviewSubmissions', review.id),
        appStoreVersion: relation('appStoreVersions', version.id),
      }));
  }
  // Never submit another person's draft item if it appeared after our preflight.
  items = (await api.list(`/v1/reviewSubmissions/${review.id}/items`, { include: 'appStoreVersion' })).data;
  if (items.length !== 1 || items[0].relationships?.appStoreVersion?.data?.id !== version.id) {
    throw new Error('Review draft contents changed or do not match this version; refusing to submit.');
  }
  const attached = await api.request('GET', `/v1/appStoreVersions/${version.id}/relationships/build`);
  if (attached.data?.id !== build.id) throw new Error('Attached build changed; refusing to submit.');
  const current = (await api.request('GET', `/v1/appStoreVersions/${version.id}`)).data;
  if (current?.attributes?.versionString !== config.version || current.attributes.platform !== 'IOS' ||
      current.attributes.releaseType !== config.releaseType ||
      !editableStates.has(current.attributes.appVersionState ?? current.attributes.appStoreState)) {
    throw new Error('Version, release mode or review state changed; refusing to submit.');
  }
  await api.request('PATCH', `/v1/reviewSubmissions/${review.id}`,
    resource('reviewSubmissions', { submitted: true }, undefined, review.id));
  const result = await api.request('GET', `/v1/reviewSubmissions/${review.id}`);
  const state = result.data?.attributes?.state;
  if (!submittedStates.has(state)) {
    throw new Error(`Submission request accepted but review state is ${state ?? 'unknown'}. Inspect App Store Connect before retrying; approval is not confirmed.`);
  }
  log(`App Review submitted: ${config.version} (${config.build}), ${state}, releaseType=${config.releaseType}. Approval is not confirmed.`);
  return { versionID: version.id, reviewID: review.id, state };
}

async function main() {
  const [command, version, build, ...extra] = process.argv.slice(2);
  if (extra.length || !['status', 'submit'].includes(command) || (command === 'submit' && (version || build))) {
    throw new Error('Usage: node scripts/app-store-review.mjs status VERSION BUILD | submit');
  }
  const config = command === 'submit' ? submissionConfiguration(process.env) : undefined;
  const privateKey = readFileSync(requireValue(process.env.APP_STORE_CONNECT_API_PRIVATE_KEY,
    'APP_STORE_CONNECT_API_PRIVATE_KEY (file path)'), 'utf8');
  const api = new AppStoreClient({ privateKey, keyID: process.env.APP_STORE_CONNECT_API_KEY_ID,
    issuerID: process.env.APP_STORE_CONNECT_API_ISSUER_ID });
  if (command === 'status') console.log(JSON.stringify(await status(api, version, build), null, 2));
  else await submit(api, config);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(`ERROR: ${error.message}`); process.exitCode = 1; });
}
