import {mkdtempSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const here=dirname(fileURLToPath(import.meta.url)); let count=0;
function test(name,platform,config,check) {
 const dir=mkdtempSync(join(tmpdir(),'tex-simple-'));
 try {
  const mock=(name,body)=>writeFileSync(join(dir,name),'#!/bin/bash\n'+body,{mode:0o755});
  mock('uname',`printf '%s\\n' '${platform}'`);
  mock('brew','printf "brew %s\\n" "$*" >> "$LOG"\ncase "$*" in "list --cask") [ -e "$INSTALLED" ] && echo mactex; exit 0;; "uninstall --cask mactex") rm "$INSTALLED";; *) exit 99;; esac');
  mock('dpkg-query','printf "%s\\n" "$INVENTORY"');
  mock('apt-get','printf "apt %s\\n" "$*" >> "$LOG"\nif [ "$1" = -s ]; then printf "%s\\n" "$PLAN"; fi\nexit "${APT_FAIL:-0}"');
  mock('sudo','printf "sudo %s\\n" "$*" >> "$LOG"\nexec "$@"');
  const log=join(dir,'calls');writeFileSync(log,'');
  const installed=join(dir,'installed'); if(config.installed) writeFileSync(installed,'');
  const env={...process.env,PATH:dir+':/usr/bin:/bin',LOG:log,INSTALLED:installed,INVENTORY:config.inventory||'',PLAN:config.plan||'',APT_FAIL:config.fail?'1':'0'};
  const result=spawnSync('/bin/bash',[join(here,platform==='Darwin'?'mac-remove.sh':'linux.sh'),config.action||'remove'],{env,encoding:'utf8'});
  check(result,readFileSync(log,'utf8'));count++;console.log('PASS '+name);
 } finally {rmSync(dir,{recursive:true,force:true});}
}
test('MacTeX removed through Homebrew, manager preserved','Darwin',{installed:true},(r,l)=>{assert.equal(r.status,0);assert.match(l,/uninstall --cask mactex/);assert.doesNotMatch(l,/zap|autoremove|force|uninstall\.sh/);});
test('Mac repeated remove is harmless','Darwin',{},(r,l)=>{assert.equal(r.status,0);assert.doesNotMatch(l,/uninstall/);});
test('Linux installed TeX packages include base/binaries/editor','Linux',{inventory:'texlive-base ii\ntexlive-binaries:amd64 ii\ntexstudio ii\ngit ii',plan:'Remv texlive-base [1]\nRemv texlive-binaries [1]\nRemv texstudio [1]'},(r,l)=>{assert.equal(r.status,0);assert.match(l,/sudo apt-get remove -y -- texlive-base texlive-binaries:amd64 texstudio/);assert.doesNotMatch(l,/purge|autoremove|git/);});
test('Linux refuses removal of unrelated reverse dependencies','Linux',{inventory:'texlive-base ii',plan:'Remv texlive-base [1]\nRemv unrelated-app [1]'},(r,l)=>{assert.notEqual(r.status,0);assert.doesNotMatch(l,/sudo/);});
test('Linux no installed TeX is harmless','Linux',{inventory:'git ii\ntexstudio rc'},(r,l)=>{assert.equal(r.status,0);assert.equal(l,'');});
test('Linux install uses explicit package list and no state','Linux',{action:'install'},(r,l)=>{assert.equal(r.status,0);assert.match(l,/apt-get install -y texlive-latex-extra/);});
test('Linux failed simulation never uninstalls','Linux',{inventory:'texlive-base ii',fail:true},(r,l)=>{assert.notEqual(r.status,0);assert.doesNotMatch(l,/sudo/);});
test('Linux invalid action does nothing','Linux',{action:'bad'},(r,l)=>{assert.equal(r.status,2);assert.equal(l,'');});
test('Linux includes bundled TeX fonts and editor support packages','Linux',{inventory:'texlive-base ii\ntipa ii\ntexstudio ii\ntexstudio-doc ii\ntexstudio-l10n ii',plan:'Remv texlive-base [1]\nRemv tipa [1]\nRemv texstudio [1]\nRemv texstudio-doc [1]\nRemv texstudio-l10n [1]'},(r,l)=>{assert.equal(r.status,0);assert.match(l,/sudo apt-get remove -y -- texlive-base tipa texstudio texstudio-doc texstudio-l10n/);});
for(const name of ['mac-remove.sh','linux.sh','windows.ps1','remove.ps1']) {
 const s=readFileSync(join(here,name),'utf8');
 assert.doesNotMatch(s,/Save-TeXRecord|Use-TeXRecord|state\.json|Remove-AppxPackage|tex_remove_manager/);
}
console.log(`${count} simplified Unix checks passed; no real package operations.`);
