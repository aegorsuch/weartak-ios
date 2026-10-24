import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { AppStoreClient, status, submissionConfiguration, submit } from '../scripts/app-store-review.mjs';

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const credentials = {
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }), keyID: 'TESTKEY',
  issuerID: '11111111-1111-1111-1111-111111111111',
};
const env = {
  CI_JOB_MANUAL: 'true', CI_COMMIT_REF_PROTECTED: 'true', CI_COMMIT_TAG: 'v5.8.5',
  CI_PIPELINE_IID: '37', CI_PIPELINE_ID: '1802065', CI_COMMIT_SHA: 'a'.repeat(40),
  APP_STORE_SUBMISSION_CONFIRM: '5.8.5 (37)', APP_STORE_WHATS_NEW: 'Route navigation improvements.',
  APP_STORE_UPLOAD_RECEIPT: 'receipt.json',
};
const receipt = {
  tag: env.CI_COMMIT_TAG, version: '5.8.5', build: '37', sha: env.CI_COMMIT_SHA,
  pipelineID: env.CI_PIPELINE_ID, uploadAccepted: true,
};
const configuration = (overrides = {}, upload = receipt, read = () => JSON.stringify(upload)) =>
  submissionConfiguration({ ...env, ...overrides }, read);
const response = (body, statusCode = 200) => new Response(JSON.stringify(body), {
  status: statusCode, headers: { 'Content-Type': 'application/json' },
});
const versionItem = (id, versionString, state) => ({
  type: 'appStoreVersions', id, attributes: { versionString, platform: 'IOS', appVersionState: state, releaseType: 'MANUAL' },
});

function fixture(options = {}) {
  const calls = [], logs = [];
  const app = { type: 'apps', id: 'app', attributes: { bundleId: 'com.aegorsuch.weartak', primaryLocale: 'en-US' } };
  let version = options.missingVersion ? undefined : versionItem('version', '5.8.5', options.versionState ?? 'PREPARE_FOR_SUBMISSION');
  let review = options.reviewState ? { type: 'reviewSubmissions', id: 'review', attributes: { state: options.reviewState } } : undefined;
  const item = { type: 'reviewSubmissionItems', id: 'item',
    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: 'version' } } } };
  let items = options.items ?? [];
  let attachedBuild = options.attachedBuild ?? 'build';
  let reads = 0;
  let clock = 0;
  const api = new AppStoreClient({
    ...credentials, wait: async () => {},
    fetchImpl: async (url, init) => {
      const body = init.body ? JSON.parse(init.body) : undefined;
      const call = { method: init.method, path: url.pathname, query: url.searchParams, body };
      calls.push(call);
      const override = options.override?.(call);
      if (override) return override;
      const path = `${init.method} ${url.pathname}`;
      switch (path) {
        case 'GET /v1/apps': return response({ data: [app] });
        case 'GET /v1/builds': {
          assert.equal(url.searchParams.get('filter[app]'), 'app');
          assert.equal(url.searchParams.get('filter[version]'), '37');
          assert.equal(url.searchParams.get('filter[preReleaseVersion.version]'), '5.8.5');
          assert.equal(url.searchParams.get('filter[preReleaseVersion.platform]'), 'IOS');
          const state = options.buildStates?.[Math.min(reads++, options.buildStates.length - 1)] ?? 'VALID';
          return response({ data: state === 'NOT_FOUND' ? [] : [{
            type: 'builds', id: 'build', attributes: { version: '37', processingState: state,
              expired: options.expired ?? false, buildAudienceType: options.audience ?? 'APP_STORE_ELIGIBLE' },
            relationships: { preReleaseVersion: { data: { id: 'pre' } }, buildBetaDetail: { data: { id: 'beta' } } },
          }], included: [
            { type: 'preReleaseVersions', id: 'pre', attributes: { version: options.buildVersion ?? '5.8.5', platform: 'IOS' } },
            { type: 'buildBetaDetails', id: 'beta', attributes: {
              internalBuildState: 'IN_BETA_TESTING', externalBuildState: 'READY_FOR_BETA_SUBMISSION',
            } },
          ] });
        }
        case 'GET /v1/apps/app/appStoreVersions':
          return response({ data: url.searchParams.has('filter[versionString]') ?
            (version ? [version] : []) : [versionItem('live', '5.8.3', 'READY_FOR_DISTRIBUTION'), ...(version ? [version] : [])] });
        case 'GET /v1/reviewSubmissions': return response({ data: review ? [review] : [] });
        case 'GET /v1/reviewSubmissions/review/items': return response({
          data: options.changedItems && calls.filter(call => call.path.endsWith('/items')).length > 1 ?
            [item, { ...item, id: 'other' }] : items,
        });
        case 'POST /v1/appStoreVersions':
          version = versionItem('version', body.data.attributes.versionString, 'PREPARE_FOR_SUBMISSION');
          Object.assign(version.attributes, body.data.attributes);
          assert.equal(body.data.relationships.app.data.id, 'app');
          assert.equal(body.data.relationships.build.data.id, 'build');
          return response({ data: version }, 201);
        case 'PATCH /v1/appStoreVersions/version':
          assert.equal(body.data.relationships.build.data.id, 'build');
          Object.assign(version.attributes, body.data.attributes);
          return response({ data: version });
        case 'GET /v1/appStoreVersions/version/appStoreVersionLocalizations':
          return response({ data: options.missingLocalization ? [] : [
            { type: 'appStoreVersionLocalizations', id: 'locale', attributes: { locale: 'en-US' } },
          ] });
        case 'PATCH /v1/appStoreVersionLocalizations/locale':
        case 'POST /v1/appStoreVersionLocalizations': return response({ data: { id: 'locale' } });
        case 'POST /v1/reviewSubmissions':
          review = { type: 'reviewSubmissions', id: 'review', attributes: { state: 'READY_FOR_REVIEW' } };
          return response({ data: review }, 201);
        case 'POST /v1/reviewSubmissionItems':
          assert.equal(body.data.relationships.appStoreVersion.data.id, 'version');
          assert.equal(body.data.relationships.reviewSubmission.data.id, 'review');
          items = [item];
          return response({ data: item }, 201);
        case 'GET /v1/appStoreVersions/version/relationships/build':
          return response({ data: { type: 'builds', id: attachedBuild } });
        case 'GET /v1/appStoreVersions/version':
          return response({ data: options.changedReleaseMode ?
            { ...version, attributes: { ...version.attributes, releaseType: 'AFTER_APPROVAL' } } : version });
        case 'PATCH /v1/reviewSubmissions/review':
          assert.deepEqual(body, { data: { type: 'reviewSubmissions', id: 'review', attributes: { submitted: true } } });
          review.attributes.state = options.submissionState ?? 'WAITING_FOR_REVIEW';
          if (options.changeBuild) attachedBuild = 'other';
          return response({ data: review });
        case 'GET /v1/reviewSubmissions/review': return response({ data: review });
        default: throw new Error(`Unexpected fixture request ${path}`);
      }
    },
  });
  return { api, calls, logs, runtime: {
    now: () => clock, wait: async ms => { clock += ms; }, log: text => logs.push(text),
  } };
}

const writes = fixture => fixture.calls.filter(call => call.method !== 'GET');

test('manual protected-tag confirmation and exact successful upload receipt are required', () => {
  assert.equal(configuration().releaseType, 'MANUAL');
  assert.equal(configuration().createVersion, false);
  for (const overrides of [
    { CI_JOB_MANUAL: undefined }, { CI_JOB_MANUAL: 'false' }, { CI_COMMIT_REF_PROTECTED: 'false' },
    { CI_COMMIT_TAG: 'main' }, { CI_PIPELINE_IID: '0' }, { CI_PIPELINE_IID: '37.0' },
    { APP_STORE_SUBMISSION_CONFIRM: undefined }, { APP_STORE_SUBMISSION_CONFIRM: '5.8.5 (36)' },
    { CI_COMMIT_SHA: 'different' }, { CI_PIPELINE_ID: 'different' },
    { APP_STORE_RELEASE_TYPE: 'SCHEDULED' }, { APP_STORE_CREATE_VERSION: 'yes' },
    { APP_STORE_PROCESSING_TIMEOUT_SECONDS: 'Infinity' }, { APP_STORE_PROCESSING_TIMEOUT_SECONDS: '29' },
  ]) assert.throws(() => configuration(overrides));
  for (const field of ['tag', 'version', 'build', 'sha', 'pipelineID', 'uploadAccepted']) {
    assert.throws(() => configuration({}, { ...receipt, [field]: 'different' }));
  }
});

test('immutable repeat-TestFlight tag keeps the same marketing version and numeric build', () => {
  const repeatReceipt = { ...receipt, tag: 'v5.8.4-testflight.1', version: '5.8.4', build: '42' };
  const config = configuration({ CI_COMMIT_TAG: repeatReceipt.tag, CI_PIPELINE_IID: '42',
    APP_STORE_SUBMISSION_CONFIRM: '5.8.4 (42)' }, repeatReceipt);
  assert.equal(config.version, '5.8.4');
  assert.equal(config.build, '42');
  for (const tag of ['v5.8.4-testflight.0', 'v5.8.4-testflight', 'v5.8.4-testflight.x', 'v5.8.4-p42']) {
    assert.throws(() => configuration({ CI_COMMIT_TAG: tag }));
  }
  const source = readFileSync(new URL('../WearTAK.xcodeproj/project.pbxproj', import.meta.url), 'utf8');
  const versions = [...source.matchAll(/MARKETING_VERSION = ([^;]+);/g)].map(match => match[1]);
  assert.deepEqual(versions, ['5.8.4', '5.8.4', '5.8.4', '5.8.4']);
});

test("What's New supports exactly one UTF-8 variable/file and validates before writes", () => {
  assert.equal(configuration({ APP_STORE_WHATS_NEW: '  Fixed navigation.  ' }).whatsNew, 'Fixed navigation.');
  assert.equal(configuration({ APP_STORE_WHATS_NEW: undefined, APP_STORE_WHATS_NEW_FILE: 'notes.txt' }, receipt,
    path => path === 'notes.txt' ? 'File notes.\n' : JSON.stringify(receipt)).whatsNew, 'File notes.');
  for (const overrides of [
    { APP_STORE_WHATS_NEW: undefined }, { APP_STORE_WHATS_NEW_FILE: 'notes.txt' },
    { APP_STORE_WHATS_NEW: ' ' }, { APP_STORE_WHATS_NEW: 'x'.repeat(4001) },
    { APP_STORE_WHATS_NEW: '\0' }, { APP_STORE_WHATS_NEW_LOCALE: 'not a locale' },
  ]) assert.throws(() => configuration(overrides));
  assert.equal(configuration({ APP_STORE_RELEASE_TYPE: 'AFTER_APPROVAL' }).releaseType, 'AFTER_APPROVAL');
});

test('ES256 JWT uses P1363 signature and short-lived Apple claims', () => {
  const api = new AppStoreClient({ ...credentials, now: () => 1_000_000 });
  const [header, claims, signature] = api.token().split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'TESTKEY', typ: 'JWT' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), {
    iss: credentials.issuerID, iat: 1000, exp: 1600, aud: 'appstoreconnect-v1',
  });
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
});

test('status reports live, preparation and exact TestFlight states with no writes', async () => {
  const f = fixture();
  const result = await status(f.api, '5.8.5', '37');
  assert.deepEqual(result.publicVersions, ['5.8.3']);
  assert.equal(result.prepareForSubmissionVersions[0].version, '5.8.5');
  assert.equal(result.processingState, 'VALID');
  assert.equal(result.internalBuildState, 'IN_BETA_TESTING');
  assert.equal(result.externalBuildState, 'READY_FOR_BETA_SUBMISSION');
  assert.deepEqual(writes(f), []);
});

test('existing unreleased version reuses version string, attaches build and submits with manual release by default', async () => {
  const f = fixture();
  const result = await submit(f.api, configuration(), f.runtime);
  assert.equal(result.state, 'WAITING_FOR_REVIEW');
  assert.equal(f.calls.some(call => call.method === 'POST' && call.path === '/v1/appStoreVersions'), false);
  const update = writes(f).find(call => call.path === '/v1/appStoreVersions/version');
  assert.deepEqual(update.body.data.attributes, { releaseType: 'MANUAL' });
  assert.equal(update.body.data.relationships.build.data.id, 'build');
  assert.equal(writes(f).find(call => call.path === '/v1/appStoreVersionLocalizations/locale')
    .body.data.attributes.whatsNew, env.APP_STORE_WHATS_NEW);
  assert.equal(writes(f).filter(call => call.body.data.attributes?.submitted).length, 1);
});

test('missing version never creates without explicit opt-in', async () => {
  const f = fixture({ missingVersion: true });
  await assert.rejects(submit(f.api, configuration(), f.runtime), /No existing App Store version/);
  assert.deepEqual(writes(f), []);
});

test('explicit opt-in creates matching version and localization; automatic release is configurable', async () => {
  const f = fixture({ missingVersion: true, missingLocalization: true });
  await submit(f.api, configuration({ APP_STORE_CREATE_VERSION: 'true', APP_STORE_RELEASE_TYPE: 'AFTER_APPROVAL' }), f.runtime);
  const create = writes(f).find(call => call.path === '/v1/appStoreVersions');
  assert.deepEqual(create.body.data.attributes, { platform: 'IOS', versionString: '5.8.5', releaseType: 'AFTER_APPROVAL' });
  assert.deepEqual(writes(f).find(call => call.path === '/v1/appStoreVersionLocalizations')
    .body.data.attributes, { locale: 'en-US', whatsNew: env.APP_STORE_WHATS_NEW });
});

test('processing waits for the exact uploaded build before any writes', async () => {
  const f = fixture({ buildStates: ['NOT_FOUND', 'PROCESSING', 'VALID'] });
  await submit(f.api, configuration(), f.runtime);
  assert.deepEqual(f.calls.slice(0, 4).map(call => call.path), ['/v1/apps', '/v1/builds', '/v1/builds', '/v1/builds']);
  assert.equal(f.logs[0], 'Build 5.8.5 (37): NOT_FOUND');
});

test('failed, invalid, expired, internal-only, wrong-version or timed-out builds never mutate Apple state', async () => {
  for (const options of [
    { buildStates: ['FAILED'] }, { buildStates: ['INVALID'] }, { expired: true },
    { audience: 'INTERNAL_ONLY' }, { buildVersion: '5.8.4' },
    { buildStates: ['PROCESSING'] }, { buildStates: ['NOT_FOUND'] },
  ]) {
    const f = fixture(options);
    await assert.rejects(submit(f.api, configuration({ APP_STORE_PROCESSING_TIMEOUT_SECONDS: '30' }), f.runtime));
    assert.deepEqual(writes(f), []);
  }
});

test('live and other locked App Store versions cannot be changed', async () => {
  for (const versionState of ['READY_FOR_DISTRIBUTION', 'READY_FOR_SALE', 'PENDING_DEVELOPER_RELEASE', 'WAITING_FOR_EXPORT_COMPLIANCE']) {
    const f = fixture({ versionState });
    await assert.rejects(submit(f.api, configuration(), f.runtime), /not editable/);
    assert.deepEqual(writes(f), []);
  }
});

test('already submitted exact build is an idempotent read-only success; another build is refused', async () => {
  const f = fixture({ versionState: 'WAITING_FOR_REVIEW' });
  assert.equal((await submit(f.api, configuration(), f.runtime)).alreadySubmitted, true);
  assert.deepEqual(writes(f), []);
  const different = fixture({ versionState: 'IN_REVIEW', attachedBuild: 'other' });
  await assert.rejects(submit(different.api, configuration(), different.runtime), /different build or release mode/);
  assert.deepEqual(writes(different), []);
});

test('reuses a matching draft item without duplicating it on retry', async () => {
  const f = fixture({ reviewState: 'READY_FOR_REVIEW', items: [{ type: 'reviewSubmissionItems', id: 'item',
    relationships: { appStoreVersion: { data: { id: 'version' } } } }] });
  await submit(f.api, configuration(), f.runtime);
  assert.equal(writes(f).some(call => call.path === '/v1/reviewSubmissions' || call.path === '/v1/reviewSubmissionItems'), false);
});

test('unrelated draft items and active reviews are refused before any writes', async () => {
  for (const options of [
    { reviewState: 'IN_REVIEW' }, { reviewState: 'UNRESOLVED_ISSUES' },
    { reviewState: 'READY_FOR_REVIEW', items: [{ id: 'item', relationships: { appStoreVersion: { data: { id: 'other' } } } }] },
    { reviewState: 'READY_FOR_REVIEW', items: [{ id: 'event', relationships: {} }] },
  ]) {
    const f = fixture(options);
    await assert.rejects(submit(f.api, configuration(), f.runtime), /active or unresolved|unrelated items/);
    assert.deepEqual(writes(f), []);
  }
});

test('changed draft contents or attached build prevent final submission', async () => {
  for (const options of [
    { reviewState: 'READY_FOR_REVIEW', changedItems: true },
    { attachedBuild: 'other' },
  ]) {
    const f = fixture(options);
    await assert.rejects(submit(f.api, configuration(), f.runtime), /draft contents|Attached build/);
    assert.equal(writes(f).some(call => call.body.data.attributes?.submitted), false);
  }
});

test('a release mode changed concurrently is not silently submitted', async () => {
  const f = fixture({ changedReleaseMode: true });
  await assert.rejects(submit(f.api, configuration(), f.runtime), /release mode.*changed/);
  assert.equal(writes(f).some(call => call.body.data.attributes?.submitted), false);
});

test('an unrelated draft is rejected even when explicitly creating a missing version', async () => {
  const f = fixture({ missingVersion: true, reviewState: 'READY_FOR_REVIEW', items: [{ id: 'event', relationships: {} }] });
  await assert.rejects(submit(f.api, configuration({ APP_STORE_CREATE_VERSION: 'true' }), f.runtime), /unrelated items/);
  assert.deepEqual(writes(f), []);
});

test('submission is not reported successful until Apple reports waiting/in review', async () => {
  const f = fixture({ submissionState: 'READY_FOR_REVIEW' });
  await assert.rejects(submit(f.api, configuration(), f.runtime), /accepted but review state/);
  assert.equal(writes(f).filter(call => call.body.data.attributes?.submitted).length, 1);
});

test('permission errors identify App Manager rights, authentication and metadata errors distinctly', async () => {
  for (const [code, message] of [[403, /App Manager or Admin/], [401, /authentication failed/],
    [422, /HTTP 422.*Metadata incomplete/]]) {
    const f = fixture({ override: call => call.method === 'PATCH' ?
      response({ errors: [{ code: 'INVALID', detail: 'Metadata incomplete' }] }, code) : undefined });
    await assert.rejects(submit(f.api, configuration(), f.runtime), message);
    assert.equal(writes(f).length, 1);
  }
});

test('safe pagination follows Apple origin only and refuses loops', async () => {
  let calls = 0;
  const api = new AppStoreClient({ ...credentials, fetchImpl: async () => {
    calls++;
    return response({ data: [{ id: String(calls) }], links: calls === 1 ?
      { next: 'https://api.appstoreconnect.apple.com/v1/apps?cursor=next' } : {} });
  } });
  assert.equal((await api.list('/v1/apps')).data.length, 2);
  for (const next of ['https://example.com/v1/apps', 'http://api.appstoreconnect.apple.com/v1/apps', '/v2/apps']) {
    api.fetch = async () => response({ data: [], links: { next } });
    await assert.rejects(api.list('/v1/apps'), /Refusing/);
  }
  api.fetch = async () => response({ data: [], links: { next: '/v1/apps?loop=true' } });
  await assert.rejects(api.list('/v1/apps'), /pagination/);
});

test('GET retries are bounded; writes and uncertain write outcomes are never blindly retried', async () => {
  let calls = 0;
  const api = new AppStoreClient({ ...credentials, wait: async () => {}, fetchImpl: async () => {
    calls++; return response({ errors: [{ code: 'UNAVAILABLE' }] }, 503);
  } });
  await assert.rejects(api.request('GET', '/v1/apps'), /HTTP 503/);
  assert.equal(calls, 3);
  calls = 0;
  await assert.rejects(api.request('POST', '/v1/appStoreVersions', {}), /HTTP 503/);
  assert.equal(calls, 1);
  api.fetch = async () => { calls++; throw new Error('Do not print underlying credential-bearing errors'); };
  calls = 0;
  await assert.rejects(api.request('POST', '/v1/reviewSubmissions', {}), /write outcome is unknown/);
  assert.equal(calls, 1);
});

test('CI keeps App Review manual-only, dependent on TestFlight, with receipt artifact', () => {
  const ci = readFileSync(new URL('../.gitlab-ci.yml', import.meta.url), 'utf8');
  const job = ci.slice(ci.indexOf('\napp_store_review_submit:'));
  assert.match(job, /job: app_store_connect_upload\s+artifacts: true/);
  assert.match(job, /CI_COMMIT_REF_PROTECTED == "true"/);
  assert.match(job, /when: manual/);
  assert.equal((job.match(/when:/g) ?? []).length, 1);
  assert.doesNotMatch(job, /APP_STORE_SUBMISSION_CONFIRM:/);
  assert.match(ci, /- build\/app-store-connect-upload.json/);
});
