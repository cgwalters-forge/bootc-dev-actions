#!/usr/bin/env node
// Runs static-checks over fixture trees built in a temporary directory and
// asserts each result. Trees are built at run time because a committed
// fixture can't contain its own .github/ directory.
// Usage: ASKALONO=/path/to/askalono node test/static-checks.js
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repo = path.join(__dirname, '..');
const script = path.join(repo, 'static-checks', 'static-checks.js');
const APACHE = fs.readFileSync(path.join(repo, 'LICENSE'), 'utf8');
const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
`;
const cargo = (license) => `[package]\nname = "fixture"\nversion = "0.1.0"\nlicense = "${license}"\n`;
const SKIP_TOML = '[skip]\nlicense = "fixture: covered by the parent project" # why\n';

const CASES = [
  { name: 'this repository', root: repo, expect: 'pass license: Apache-2.0 (LICENSE)' },
  { name: 'no license', files: { 'README.md': 'x\n' }, expect: 'fail license: no LICENSE' },
  {
    name: 'unrecognized license',
    files: { LICENSE: 'All rights reserved. You may not use this.\n' },
    expect: 'fail license: LICENSE is not recognized',
  },
  {
    name: 'apache with package.json',
    files: { LICENSE: APACHE, 'package.json': '{"license": "Apache-2.0"}\n' },
    expect: 'pass license: Apache-2.0',
  },
  {
    name: 'dual MIT/Apache',
    files: { 'LICENSE-APACHE': APACHE, 'LICENSE-MIT': MIT, 'Cargo.toml': cargo('MIT OR Apache-2.0') },
    expect: 'pass license: Apache-2.0, MIT (LICENSE-APACHE, LICENSE-MIT)',
  },
  {
    name: 'Cargo.toml mismatch',
    files: { LICENSE: APACHE, 'Cargo.toml': cargo('MIT') },
    expect: 'fail license: Cargo.toml [package] declares "MIT"',
  },
  {
    name: 'skip with reason',
    files: { '.github/static-checks.toml': SKIP_TOML },
    skip: 'license',
    expect: 'skip license: fixture: covered by the parent project',
  },
  {
    name: 'skip without reason',
    files: { LICENSE: APACHE },
    skip: 'license',
    expect: 'fail license: skipped without a reason',
  },
];

let failures = 0;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'static-checks-'));
for (const [i, c] of CASES.entries()) {
  let root = c.root;
  if (!root) {
    root = path.join(tmp, String(i));
    for (const [name, content] of Object.entries(c.files)) {
      fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
      fs.writeFileSync(path.join(root, name), content);
    }
  }
  const env = { ...process.env, INPUT_CHECKS: 'all', INPUT_SKIP: c.skip || '', GITHUB_STEP_SUMMARY: '' };
  const r = spawnSync(process.execPath, [script, root], { encoding: 'utf8', env });
  const wantStatus = c.expect.startsWith('fail') ? 1 : 0;
  const ok = r.status === wantStatus && r.stdout.includes(c.expect);
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${c.name}`);
  if (!ok) {
    failures++;
    console.log(`  expected exit ${wantStatus} and "${c.expect}", got exit ${r.status}:\n${r.stdout}${r.stderr}`);
  }
}
fs.rmSync(tmp, { recursive: true, force: true });
process.exitCode = failures ? 1 : 0;
