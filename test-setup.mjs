// Offline checks: only package-manager bootstrap, never real installations.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
const dir=dirname(fileURLToPath(import.meta.url));
const root=mkdtempSync(join(tmpdir(),'tex-bootstrap-test-'));
let count=0;
function check(name,fn) { fn(); console.log('PASS '+name); count++; }
const mac=readFileSync(join(dir,'mac.sh'),'utf8');
const win=readFileSync(join(dir,'win.ps1'),'utf8');
function simulate({missing=false, failDownload=false, failUpdate=false, shell='/bin/bash'}={}) {
  const tmp=mkdtempSync(join(root,'case-'));
  const bin=join(tmp,'bin'); mkdirSync(bin);
  const calls=join(tmp,'calls');
  function executable(p,s) { writeFileSync(p,'#!/bin/bash\n'+s+'\n',{mode:0o755}); }
  executable(join(bin,'uname'),'echo Darwin');
  const brew='printf "%s\\n" "$*" >> "$TEST_LOG"\n'+
    'if [[ $1 == shellenv ]]; then printf \'export PATH="'+bin+':$PATH"\\n\'; fi\n'+
    (failUpdate?'if [[ $1 == update ]]; then exit 8; fi\n':'')+'exit 0';
  executable(join(tmp,'brew-template'),brew);
  if(!missing) executable(join(bin,'brew'),brew);
  executable(join(bin,'curl'), failDownload?'exit 22':
    'printf \'cp "'+tmp+'/brew-template" "'+bin+'/brew"\\n\'');
  const source=mac.replaceAll('/opt/homebrew/bin/brew',join(bin,'brew'))
    .replaceAll('/usr/local/bin/brew',join(tmp,'no-intel-brew'));
  const f=join(tmp,'source.sh'); writeFileSync(f,source);
  const result=spawnSync(shell,['-c','. "'+f+'" && command -v brew'],{
    encoding:'utf8',env:{PATH:bin+':/usr/bin:/bin',TEST_LOG:calls,LANG:'C'}});
  let logged=''; try { logged=readFileSync(calls,'utf8'); } catch {}
  return {...result,logged};
}
function simulateTeX({missingEditor=false,failRepair=false,failUpdate=false,shell='/bin/bash'}={}) {
  const tmp=mkdtempSync(join(root,'tex-update-'));
  const bin=join(tmp,'bin'); mkdirSync(bin);
  const calls=join(tmp,'calls'); const editor=join(tmp,'TeXShop');
  function executable(p,s) { writeFileSync(p,'#!/bin/bash\n'+s+'\n',{mode:0o755}); }
  executable(join(bin,'tlmgr'),'echo "tlmgr $*" >> "$TEST_LOG"\nexit '+(failUpdate?9:0));
  executable(join(bin,'sudo'),'"$@"');
  executable(join(bin,'brew'),'echo "brew $*" >> "$TEST_LOG"\nexit '+(failRepair?8:0));
  if(!missingEditor) executable(editor,'exit 0');
  const source=mac.slice(0,mac.indexOf('tex_setup_homebrew()'))
    .replaceAll('/Library/TeX/texbin/tlmgr',join(bin,'tlmgr'))
    .replaceAll('/Applications/TeX/TeXShop.app/Contents/MacOS/TeXShop',editor);
  const f=join(tmp,'update.sh'); writeFileSync(f,source+'\ntex_update\n');
  const result=spawnSync(shell,[f],{encoding:'utf8',env:{PATH:bin+':/usr/bin:/bin',TEST_LOG:calls}});
  let logged=''; try { logged=readFileSync(calls,'utf8'); } catch {}
  return {...result,logged};
}
check('Bash and zsh syntax',()=>{
  for(const sh of ['/bin/bash','/bin/zsh'])
    assert.equal(spawnSync(sh,['-n',join(dir,'mac.sh')]).status,0);
});
for(const shell of ['/bin/bash','/bin/zsh']) {
  check(shell+' TeX update uses tlmgr self and all',()=>{
    const r=simulateTeX({shell}); assert.equal(r.status,0,r.stderr);
    assert.equal(r.logged,'tlmgr update --self --all\n');
  });
  check(shell+' missing TeXShop repaired then updated',()=>{
    const r=simulateTeX({shell,missingEditor:true}); assert.equal(r.status,0,r.stderr);
    assert.equal(r.logged,'brew reinstall --cask mactex\ntlmgr update --self --all\n');
  });
  check(shell+' failed editor repair stops update',()=>{
    const r=simulateTeX({shell,missingEditor:true,failRepair:true}); assert.notEqual(r.status,0);
    assert.equal(r.logged,'brew reinstall --cask mactex\n');
  });
  check(shell+' TeX update errors propagate',()=>{
    const r=simulateTeX({shell,failUpdate:true}); assert.notEqual(r.status,0);
  });
  check(shell+' existing Homebrew updated and available',()=>{
    const r=simulate({shell}); assert.equal(r.status,0,r.stderr);
    assert.match(r.logged,/update\nshellenv/); assert.match(r.stdout,/\/bin\/brew/);
    assert.doesNotMatch(r.logged,/install|upgrade/);
  });
  check(shell+' missing Homebrew bootstrapped and available',()=>{
    const r=simulate({shell,missing:true}); assert.equal(r.status,0,r.stderr);
    assert.match(r.logged,/update\nshellenv/); assert.match(r.stdout,/\/bin\/brew/);
  });
  check(shell+' failed download stops setup',()=>{
    const r=simulate({shell,missing:true,failDownload:true});
    assert.notEqual(r.status,0); assert.equal(r.logged,'');
  });
  check(shell+' failed update stops before shellenv',()=>{
    const r=simulate({shell,failUpdate:true});
    assert.notEqual(r.status,0); assert.equal(r.logged,'update\n');
  });
}
check('Windows bootstrap exposes validated executable, no distro install',()=>{
  assert.match(win,/Repair-WinGetPackageManager -Latest/);
  assert.match(win,/Get-AppxPackage Microsoft.DesktopAppInstaller/);
  assert.match(win,/\$env:Path = \(Split-Path -Parent \$wg\)/);
  assert.match(win,/\$LASTEXITCODE -ne 0/);
  assert.doesNotMatch(win,/Set-ExecutionPolicy|Bypass/);
  assert.match(win,/function Update-TeX/);
  assert.match(win,/packages','update'/);
  assert.match(win,/TeXworks\.lnk/);
});
check('No setup history, deletion code or private data in installation helpers',()=>{
  for(const s of [mac,win]) assert.doesNotMatch(s,/state\.json|track\.|\/Users\/|champcademy|ghp_|github_pat_|rm -rf|--zap/i);
});
console.log(count+' checks passed; no real package installation, no Windows runtime test.');
