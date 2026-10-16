// Offline tests. All installer/network commands are replaced by mocks.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const dir = dirname(fileURLToPath(import.meta.url));
const temp = mkdtempSync(join(tmpdir(), 'tex-setup-tests-'));
const q = s => "'" + s.replaceAll("'", "'\\''") + "'";
let passed = 0;
function test(name, check) { check(); passed++; console.log('PASS ' + name); }
function fixture(platform, options = {}) {
  const root = mkdtempSync(join(temp, platform + '-'));
  const bin = join(root, 'bin'); mkdirSync(bin);
  const log = join(root, 'calls');
  const put = (name, code) => writeFileSync(join(bin, name), '#!/bin/bash\n' + code + '\n', {mode:0o755});
  const record = 'printf "%s\\n" "$0 $*" >> "$TEST_LOG"\n';
  put('uname', `printf '%s\\n' ${q(platform === 'mac' ? 'Darwin' : 'Linux')}`);
  if (platform === 'mac') {
    put('uname', 'if [[ $1 == -m ]]; then echo arm64; else echo Darwin; fi');
    put('sysctl', 'echo 0'); put('sw_vers', 'echo 15.0');
    const brewCode = record + `if [[ $1 == list ]]; then exit ${options.managed ? 0 : 1}; fi\nexit ${options.failBrew ? 9 : 0}`;
    writeFileSync(join(root, 'brew-mock'), '#!/bin/bash\n' + brewCode, {mode:0o755});
    if (!options.noBrew) put('brew', brewCode);
    put('curl', record + (options.failDownload ? 'exit 22' : `printf '%s\\n' ${q(`mkdir -p ${q(root + '/opt/homebrew/bin')}; cp ${q(root + '/brew-mock')} ${q(root + '/opt/homebrew/bin/brew')}`)}`));
    for (const app of ['open', 'sudo']) put(app, record);
    if (options.installed) {
      mkdirSync(root + '/Library/TeX/texbin', {recursive:true});
      writeFileSync(root + '/Library/TeX/texbin/tlmgr', '#!/bin/bash\nexit 0\n', {mode:0o755});
      mkdirSync(root + '/Applications/TeX/TeXShop.app', {recursive:true});
    }
    if (options.foreign) put('pdflatex', 'echo MiKTeX');
  } else {
    put('apt-get', record + `exit ${options.failApt ? 7 : 0}`);
    put('sudo', '"$@"');
    put('dpkg-query', `echo '${options.foreign ? 'other' : 'texlive-binaries'}: /usr/bin/pdflatex'; exit ${options.foreign ? 1 : 0}`);
    if (options.installed || options.foreign) put('pdflatex', 'echo pdfTeX');
  }
  let source = readFileSync(join(dir, platform + '.sh'), 'utf8').replace(/main "\$@"\s*$/, '');
  if (platform === 'mac') {
    source = source.replaceAll('/Library/TeX', root + '/Library/TeX')
      .replaceAll('/Applications/TeX', root + '/Applications/TeX')
      .replaceAll('/opt/homebrew', root + '/opt/homebrew')
      .replaceAll('/usr/local/bin/brew', root + '/usr/local/bin/brew');
    // A simulated successful installer creates the expected program, never on the host.
    source += `\ndirect_mactex() { printf 'direct_mactex\\n' >> "$TEST_LOG"; }\n`;
    if (!options.installed && !options.foreign) {
      source = source.replace('[[ -x ' + root + '/Library/TeX/texbin/tlmgr ]] || fail', 'true || fail');
    }
  }
  const script = join(root, 'test.sh'); writeFileSync(script, source + '\nmain\n');
  const result = spawnSync('/bin/bash', [script], {encoding:'utf8', env:{PATH:bin+':/usr/bin:/bin', TEST_LOG:log, LANG:'C', DISPLAY:'', WAYLAND_DISPLAY:''}});
  let calls = ''; try { calls = readFileSync(log, 'utf8'); } catch {}
  return {...result, calls};
}

test('bash syntax mac/linux', () => {
  for (const file of ['mac.sh', 'linux.sh']) assert.equal(spawnSync('/bin/bash', ['-n', join(dir,file)]).status, 0);
});
test('Mac fresh install uses only mactex cask', () => {
  const r=fixture('mac'); assert.equal(r.status,0,r.stderr); assert.match(r.calls,/install --cask mactex/); assert.doesNotMatch(r.calls,/upgrade --cask/);
});
test('Mac managed installation updated', () => {
  const r=fixture('mac',{installed:true,managed:true}); assert.equal(r.status,0,r.stderr); assert.match(r.calls,/upgrade --cask mactex/);
});
test('Mac unmanaged installation not adopted by brew', () => {
  const r=fixture('mac',{installed:true}); assert.equal(r.status,0,r.stderr); assert.match(r.calls,/direct_mactex/); assert.doesNotMatch(r.calls,/install --cask/);
});
test('Mac missing Homebrew bootstrap', () => {
  const r=fixture('mac',{noBrew:true}); assert.equal(r.status,0,r.stderr); assert.match(r.calls,/install\/HEAD\/install.sh/); assert.match(r.calls,/install --cask mactex/);
});
test('Mac download failure prevents installation', () => {
  const r=fixture('mac',{noBrew:true,failDownload:true}); assert.notEqual(r.status,0); assert.doesNotMatch(r.calls,/install --cask|sudo|open /);
});
test('Mac brew update failure stops subsequent installation', () => {
  const r=fixture('mac',{failBrew:true}); assert.notEqual(r.status,0); assert.doesNotMatch(r.calls,/install --cask|sudo|open /);
});
test('Mac foreign TeX causes safe stop before changes', () => {
  const r=fixture('mac',{foreign:true}); assert.notEqual(r.status,0); assert.equal(r.calls,'');
});
test('Linux new install uses exact package list', () => {
  const r=fixture('linux'); assert.equal(r.status,0,r.stderr); assert.match(r.calls,/install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio/);
});
test('Linux existing distro installation can be updated', () => {
  const r=fixture('linux',{installed:true}); assert.equal(r.status,0,r.stderr);
});
test('Linux foreign TeX stops before apt', () => {
  const r=fixture('linux',{foreign:true}); assert.notEqual(r.status,0); assert.equal(r.calls,'');
});
test('Linux apt failure stops install', () => {
  const r=fixture('linux',{failApt:true}); assert.notEqual(r.status,0); assert.doesNotMatch(r.calls,/install -y/);
});
test('Windows source safety invariants (not a runtime test)', () => {
  const s=readFileSync(join(dir,'win.ps1'),'utf8');
  assert.doesNotMatch(s,/Set-ExecutionPolicy|ExecutionPolicy Bypass|Invoke-Expression|--ignore-security-hash|--disable-interactivity/);
  assert.match(s,/Repair-WinGetPackageManager -Latest/);
  assert.match(s,/\$LASTEXITCODE -ne 0/);
  assert.match(s,/'packages', 'update'/);
  assert.doesNotMatch(s,/Invoke-Checked \$winget @\('upgrade'/);
  assert.match(s,/if \(-not \$miktex\)/);
});
test('No secrets, personal paths, broad cleanup or all-app upgrades in published files', () => {
  for (const file of ['mac.sh','linux.sh','win.ps1','HINWEISE.txt']) {
    const s=readFileSync(join(dir,file),'utf8');
    assert.doesNotMatch(s,/\/Users\/|champcademy|lehepete|ghp_|github_pat_|rm -rf|autoremove|--zap|winget upgrade --all/);
  }
});
console.log(`${passed} tests passed. Windows has not been executed on a Windows host.`);
