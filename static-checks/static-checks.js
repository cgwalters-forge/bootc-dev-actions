#!/usr/bin/env node
// Repository hygiene checks. Each entry in CHECKS inspects the tree given
// as argv[2] and returns { ok, message, hint }; add a check by adding an
// entry. Environment: INPUT_CHECKS, INPUT_SKIP, ASKALONO (path to the
// askalono binary), and optionally GITHUB_STEP_SUMMARY.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CONFIG_FILE = '.github/static-checks.toml';
const ORG_LICENSE_HINT = 'this org uses Apache-2.0 OR MIT';
const LICENSE_FILE_RE = /^(LICEN[CS]E|COPYING)([.-].+)?$/i;
const ASKALONO_TIMEOUT_MS = 60_000;

// SPDX license ids named by an expression such as "MIT OR Apache-2.0",
// "(MIT/Apache-2.0)" (legacy Cargo syntax) or "GPL-2.0 WITH x"; exception
// names after WITH are not licenses and are dropped.
function spdxIds(expr) {
  const tokens = expr.replace(/[()/]/g, ' ').split(/\s+/).filter(Boolean);
  const ids = new Set();
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t === 'WITH') i++;
    else if (t !== 'OR' && t !== 'AND') ids.add(t);
  }
  return ids;
}

// Declared license expressions from package manifests, as [source, expr].
function declaredLicenses(root) {
  const found = [];
  const cargo = path.join(root, 'Cargo.toml');
  if (fs.existsSync(cargo)) {
    let section = '';
    for (const line of fs.readFileSync(cargo, 'utf8').split('\n')) {
      const header = line.match(/^\s*\[([^\]]+)\]/);
      if (header) section = header[1].trim();
      const m = line.match(/^\s*license\s*=\s*["']([^"']*)["']/);
      if (m && (section === 'package' || section === 'workspace.package')) {
        found.push([`Cargo.toml [${section}]`, m[1]]);
      }
    }
  }
  const pkg = path.join(root, 'package.json');
  if (fs.existsSync(pkg)) {
    let license;
    try {
      license = JSON.parse(fs.readFileSync(pkg, 'utf8')).license;
    } catch (e) {
      throw new Error(`parsing package.json: ${e.message}`);
    }
    if (typeof license === 'string') found.push(['package.json', license]);
  }
  return found;
}

function identify(file) {
  const r = spawnSync(process.env.ASKALONO || 'askalono', ['--format', 'json', 'identify', file], {
    encoding: 'utf8',
    timeout: ASKALONO_TIMEOUT_MS,
  });
  if (r.error) throw new Error(`running askalono: ${r.error.message}`);
  let out;
  try {
    out = JSON.parse(r.stdout);
  } catch {
    throw new Error(`askalono failed on ${file} (exit ${r.status}): ${r.stderr.trim()}`);
  }
  // An unrecognized text is reported as { error: "Confidence threshold ..." }.
  return out.result?.license?.name ?? null;
}

function checkLicense(root) {
  const files = fs
    .readdirSync(root, { withFileTypes: true })
    .filter((e) => !e.isDirectory() && LICENSE_FILE_RE.test(e.name))
    .map((e) => e.name)
    .sort();
  if (files.length === 0) {
    return { ok: false, message: 'no LICENSE, LICENSE-* or COPYING file', hint: `add LICENSE; ${ORG_LICENSE_HINT}` };
  }
  const detected = new Set();
  for (const f of files) {
    const id = identify(path.join(root, f));
    if (!id) {
      return {
        ok: false,
        message: `${f} is not recognized as an SPDX license`,
        hint: `use the unmodified license text; ${ORG_LICENSE_HINT}`,
      };
    }
    detected.add(id);
  }
  const fileIds = [...detected].sort().join(', ');
  for (const [source, expr] of declaredLicenses(root)) {
    const declared = [...spdxIds(expr)].sort().join(', ');
    if (declared !== fileIds) {
      return {
        ok: false,
        message: `${source} declares "${expr}" but ${files.join(', ')} detected as ${fileIds}`,
        hint: 'make the license field and the license files agree',
      };
    }
  }
  return { ok: true, message: `${fileIds} (${files.join(', ')})` };
}

const CHECKS = {
  license: checkLicense,
};

// Minimal TOML subset: a [skip] table of `name = "reason"` lines.
function readSkipReasons(root) {
  const file = path.join(root, CONFIG_FILE);
  const reasons = new Map();
  if (!fs.existsSync(file)) return reasons;
  let section = '';
  for (const [i, raw] of fs.readFileSync(file, 'utf8').split('\n').entries()) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const header = line.match(/^\[([^\]]+)\]$/);
    if (header) {
      section = header[1].trim();
      continue;
    }
    if (section !== 'skip') continue;
    const m = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')\s*(#.*)?$/);
    if (!m) throw new Error(`${CONFIG_FILE}:${i + 1}: expected name = "reason" under [skip]`);
    reasons.set(m[1], (m[2] ?? m[3]).trim());
  }
  return reasons;
}

// Workflow command data escaping, so file names can't inject commands.
function escapeCommand(s) {
  return s.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

function parseList(s) {
  return (s || '').split(/[\s,]+/).filter(Boolean);
}

function main() {
  const root = process.argv[2] || '.';
  const wanted = (process.env.INPUT_CHECKS || 'all').trim() === 'all' ? Object.keys(CHECKS) : parseList(process.env.INPUT_CHECKS);
  const skipInput = parseList(process.env.INPUT_SKIP);
  for (const name of [...wanted, ...skipInput]) {
    if (!(name in CHECKS)) throw new Error(`unknown check "${name}"; known: ${Object.keys(CHECKS).join(', ')}`);
  }
  const reasons = readSkipReasons(root);
  const results = [];
  for (const name of wanted) {
    const reason = reasons.get(name);
    if (reason) {
      results.push({ name, status: 'skip', message: reason });
    } else if (skipInput.includes(name) || reasons.has(name)) {
      results.push({
        name,
        status: 'fail',
        message: 'skipped without a reason',
        hint: `record why under [skip] in ${CONFIG_FILE}, e.g. ${name} = "reason"`,
      });
    } else {
      let r;
      try {
        r = CHECKS[name](root);
      } catch (e) {
        r = { ok: false, message: `error: ${e.message}` };
      }
      results.push({ name, status: r.ok ? 'pass' : 'fail', message: r.message, hint: r.hint });
    }
  }

  for (const r of results) {
    const hint = r.hint ? ` (fix: ${r.hint})` : '';
    if (r.status === 'fail') console.log(`::error title=static-checks ${r.name}::${escapeCommand(r.message + hint)}`);
    console.log(`${r.status.padEnd(4)} ${r.name}: ${r.message}${hint}`);
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    const cell = (s) => (s || '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
    const rows = results.map((r) => `| ${r.name} | ${r.status} | ${cell(r.message)} | ${cell(r.hint)} |`);
    const table = ['## Static checks', '', '| Check | Result | Detail | Fix |', '| --- | --- | --- | --- |', ...rows, ''];
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, table.join('\n'));
  }
  if (results.some((r) => r.status === 'fail')) process.exitCode = 1;
}

try {
  main();
} catch (e) {
  console.log(`::error title=static-checks::${escapeCommand(e.message)}`);
  process.exitCode = 1;
}
