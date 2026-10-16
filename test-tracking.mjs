// Isolated fixtures only. All package-manager and sudo effects are mocked.
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,existsSync,symlinkSync,unlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const dir=dirname(fileURLToPath(import.meta.url));
const original=readFileSync(join(dir,'track.sh'),'utf8');
const root=mkdtempSync(join(tmpdir(),'tex-tracking-tests-'));
let count=0;
const installMac='tex_install brew install --cask mactex';
const installLinux='tex_install sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio';
function check(name,fn){fn(); console.log('PASS '+name); count++;}
function fixture({os='Darwin',shell='/bin/bash',existing=false,failInstall=false,failRemove=false,dependent=false,changed=false,failBootstrap=false}={}){
  const tmp=mkdtempSync(join(root,'case-')),bin=join(tmp,'bin'),user=join(tmp,'user');
  mkdirSync(bin); mkdirSync(user);
  const paths=['/Applications/TeXShop.app','/Applications/TeX','/Library/TeX','/usr/local/texlive','/etc/paths.d/TeX','/etc/manpaths.d/TeX'];
  const app=join(tmp,'Applications/TeX');
  const db=join(tmp,'db'),calls=join(tmp,'calls');
  writeFileSync(db,existing?'texstudio\tii \t1\n':'');
  if(existing){mkdirSync(app,{recursive:true});writeFileSync(join(app,'preexisting'),'keep');}
  let source=original;
  for(const p of paths)source=source.replaceAll(p,tmp+p);
  source=source.replaceAll('/opt/homebrew/bin/brew',join(bin,'brew')).replaceAll('/usr/local/bin/brew',join(bin,'brew'));
  const script=join(tmp,'track.sh');writeFileSync(script,source);
  function executable(name,body){writeFileSync(join(bin,name),'#!/bin/bash\nset -eu\n'+body+'\n',{mode:0o755});}
  executable('uname',`echo ${os}`);
  executable('sudo','exec "$@"');
  executable('curl',`printf '%s\\n' 'bootstrap' >> "${calls}"; ${failBootstrap?'echo "touch '+tmp+'/partial-executed"; exit 22':'echo ":"'}`);
  executable('brew',`printf '%s\n' "$*" >> "${calls}"
case "$1" in
list) if [ -f "${tmp}/installed" ]; then echo 'mactex 2026.0324'; elif [ "$2" = --cask ] && [ "$3" = mactex ]; then exit 1; fi ;;
install) mkdir -p "${app}"; echo installed > "${app}/program"; touch "${tmp}/installed"; ${failInstall?'exit 9':'exit 0'} ;;
uninstall) ${failRemove?'exit 7':`rm "${app}/program" "${tmp}/installed"; rmdir "${app}"`} ;;
*) exit 88 ;;
esac`);
  executable('dpkg-query',`cat "${db}"`);
  executable('apt-get',`printf '%s\n' "$*" >> "${calls}"
if [[ "$*" == *--simulate* ]]; then
 if [[ "$*" == *' remove '* ]]; then
   echo 'Remv texstudio [1]'; ${dependent?"echo 'Remv other-app [1]'":':'}
 else echo 'Inst texstudio (1)'; echo 'Inst texlive-base (1)'; fi
elif [[ "$*" == *install* ]]; then
 printf 'texstudio\tii \t2\ntexlive-base\tii \t1\n' > "${db}"
 ${failInstall?'exit 9':':'}
fi`);
  executable('dpkg',`printf '%s\n' "$*" >> "${calls}"
if [ "$1" = --verify ]; then ${changed?"echo '??5?????? /usr/bin/texstudio'":':'}
elif [ "$1" = --remove ]; then
 ${failRemove?'exit 7':`awk '$1=="texstudio" {print "texstudio\\trc \\t2"; next} $1=="texlive-base" {print "texlive-base\\trc \\t1"; next} {print}' "${db}" > "${db}.new"; mv "${db}.new" "${db}"`}
else exit 99; fi`);
  const state=os==='Darwin'?join(user,'Library/Application Support/TeX-Setup'):join(user,'.local/state/tex-setup');
  function run(command){const r=spawnSync(shell,['-c',`. "${script}"; ${command}`],{encoding:'utf8',env:{HOME:user,PATH:bin+':/usr/bin:/bin',LANG:'C'}}); if(r.status!==0)r.stderr+='\nFixture: '+tmp; return r;}
  return{tmp,app,state,run,calls,db,install:os==='Darwin'?installMac:installLinux,log:()=>existsSync(calls)?readFileSync(calls,'utf8'):''};
}
for(const shell of ['/bin/bash','/bin/zsh']) {
  check(shell+' syntax',()=>assert.equal(spawnSync(shell,['-n',join(dir,'track.sh')]).status,0));
  check(shell+' missing record does nothing',()=>{const f=fixture({shell});const r=f.run('tex_remove');assert.equal(r.status,0,r.stderr);assert.equal(f.log(),'');assert.equal(existsSync(f.state),false);});
  check(shell+' fresh MacTeX recorded and removed, record deleted',()=>{const f=fixture({shell});let r=f.run(f.install);assert.equal(r.status,0,r.stderr);r=f.run('tex_remove');assert.equal(r.status,0,r.stderr);assert.match(f.log(),/uninstall --cask mactex/);assert.equal(existsSync(f.state),false);});
  check(shell+' existing MacTeX and updates preserved',()=>{const f=fixture({shell,existing:true});let r=f.run(f.install);assert.equal(r.status,0,r.stderr);r=f.run('tex_remove');assert.equal(r.status,0,r.stderr);assert.doesNotMatch(f.log(),/uninstall/);assert.ok(existsSync(join(f.app,'preexisting')));});
  check(shell+' repeated install retains original ownership',()=>{const f=fixture({shell});assert.equal(f.run(f.install).status,0);assert.equal(f.run(f.install).status,0);assert.equal(readFileSync(join(f.state,'baseline'),'utf8'),'mac-absent\n');assert.equal(f.run('tex_remove').status,0);});
  check(shell+' interrupted install cannot become owned on retry',()=>{const f=fixture({shell,failInstall:true});assert.notEqual(f.run(f.install).status,0);assert.notEqual(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/uninstall/);assert.ok(existsSync(join(f.state,'pending')));});
  check(shell+' changed program folder preserved',()=>{const f=fixture({shell});assert.equal(f.run(f.install).status,0);writeFileSync(join(f.app,'my-thesis.tex'),'private');assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/uninstall/);assert.ok(existsSync(join(f.state,'completed')));});
  check(shell+' removal error retains record',()=>{const f=fixture({shell,failRemove:true});assert.equal(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.ok(existsSync(join(f.state,'completed')));});
  check(shell+' corrupt schema fails closed',()=>{const f=fixture({shell});assert.equal(f.run(f.install).status,0);writeFileSync(join(f.state,'schema'),'corrupt');assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/uninstall/);});
  check(shell+' record symlink rejected',()=>{const f=fixture({shell});assert.equal(f.run(f.install).status,0);unlinkSync(join(f.state,'owned'));symlinkSync(f.db,join(f.state,'owned'));assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/uninstall/);});
  check(shell+' simultaneous operation rejected',()=>{const f=fixture({shell});assert.equal(f.run(f.install).status,0);mkdirSync(join(f.state,'lock'));assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/uninstall/);});
  check(shell+' invalid install command has no effects',()=>{const f=fixture({shell});assert.notEqual(f.run('tex_install brew install other-app').status,0);assert.equal(f.log(),'');});
  check(shell+' preparation is automatic and precedes installation',()=>{const f=fixture({shell});const r=f.run(f.install);assert.equal(r.status,0,r.stderr);assert.match(f.log(),/^bootstrap\n/);assert.ok(f.log().indexOf('bootstrap')<f.log().indexOf('install --cask'));});
  check(shell+' failed bootstrap blocks install and partial script execution',()=>{const f=fixture({shell,failBootstrap:true});assert.notEqual(f.run(f.install).status,0);assert.doesNotMatch(f.log(),/install --cask/);assert.equal(existsSync(join(f.tmp,'partial-executed')),false);assert.equal(existsSync(join(f.state,'pending')),false);});
}
for(const shell of ['/bin/bash','/bin/zsh']) {
  check(shell+' Linux new packages and planned dependencies removed',()=>{const f=fixture({shell,os:'Linux'});let r=f.run(f.install);assert.equal(r.status,0,r.stderr);assert.equal(readFileSync(join(f.state,'owned'),'utf8'),'texlive-base\ntexstudio\n');r=f.run('tex_remove');assert.equal(r.status,0,r.stderr);assert.match(f.log(),/--remove texlive-base texstudio/);});
  check(shell+' Linux existing packages excluded from ownership',()=>{const f=fixture({shell,os:'Linux',existing:true});const r=f.run(f.install);assert.equal(r.status,0,r.stderr);assert.equal(readFileSync(join(f.state,'owned'),'utf8'),'texlive-base\n');});
  check(shell+' Linux dependent foreign program prevents removal',()=>{const f=fixture({shell,os:'Linux',dependent:true});assert.equal(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/^--remove/m);assert.ok(existsSync(join(f.state,'completed')));});
  check(shell+' Linux modified package protected',()=>{const f=fixture({shell,os:'Linux',changed:true});assert.equal(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/^--remove/m);});
  check(shell+' Linux failed install cannot be removed',()=>{const f=fixture({shell,os:'Linux',failInstall:true});assert.notEqual(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.doesNotMatch(f.log(),/^--remove/m);});
  check(shell+' Linux error retains record for retry',()=>{const f=fixture({shell,os:'Linux',failRemove:true});assert.equal(f.run(f.install).status,0);assert.notEqual(f.run('tex_remove').status,0);assert.ok(existsSync(join(f.state,'completed')));});
}
check('No broad recursive deletion or system-policy bypass',()=>{
 for(const file of ['track.sh','track.ps1'])assert.doesNotMatch(readFileSync(join(dir,file),'utf8').split('\n').filter(l=>!l.trimStart().startsWith('#')).join('\n'),/rm -rf|Remove-Item[^\n]*-Recurse|--zap|--autoremove|--purge|Set-ExecutionPolicy/);
});
console.log(count+' isolated tracking checks passed. No real installations/removals.');
