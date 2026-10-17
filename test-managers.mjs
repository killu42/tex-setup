// All executables, prefixes and home directories are isolated fixtures.
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,existsSync,symlinkSync,unlinkSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const dir=dirname(fileURLToPath(import.meta.url));
const original=readFileSync(join(dir,'track.sh'),'utf8');
const root=mkdtempSync(join(tmpdir(),'tex-manager-tests-'));
let count=0;
function check(name,fn){fn();console.log('PASS '+name);count++;}
function fixture(shell,{existing=false,broken=false,failDownload=false,failBootstrap=false,failRemove=false}={}){
 const tmp=mkdtempSync(join(root,'case-')),bin=join(tmp,'bin'),user=join(tmp,'user');
 const prefix=join(tmp,'brew'),intel=join(tmp,'intel'),app=join(tmp,'Applications/TeX'),log=join(tmp,'calls');
 mkdirSync(bin);mkdirSync(user);
 const state=join(user,'Library/Application Support/TeX-Setup'),manager=state+'-manager';
 const source=original.replaceAll('/opt/homebrew',prefix).replaceAll('/usr/local',intel)
   .replaceAll('/Applications/TeX',app).replaceAll('/Library/TeX',join(tmp,'Library/TeX'))
   .replaceAll('/etc/paths.d/TeX',join(tmp,'paths/TeX')).replaceAll('/etc/manpaths.d/TeX',join(tmp,'manpaths/TeX'));
 const script=join(tmp,'track.sh');writeFileSync(script,source);
 function executable(path,body){writeFileSync(path,'#!/bin/bash\nset -eu\n'+body+'\n',{mode:0o755});}
 executable(join(bin,'uname'),'if [ "$1" = -m ]; then echo arm64; else echo Darwin; fi');
 const template=join(tmp,'brew-template');
 executable(template,`case "$1" in
 --prefix) echo "${prefix}" ;;
 list) if [ -f "${prefix}/mactex" ]; then echo 'mactex 2026'; elif [ "$3" = mactex ]; then exit 1; fi ;;
 install) mkdir -p "${app}"; echo program > "${app}/program"; echo installed > "${prefix}/mactex" ;;
 uninstall) rm "${app}/program" "${prefix}/mactex"; rmdir "${app}" ;;
 *) exit 88 ;; esac`);
 if(existing||broken){mkdirSync(join(prefix,'bin'),{recursive:true});if(existing)writeFileSync(join(prefix,'bin/brew'),readFileSync(template),{mode:0o755});}
 const bootstrap=join(tmp,'bootstrap.sh');
 writeFileSync(bootstrap,failBootstrap?'false\ntouch "'+tmp+'/bad"\n':`mkdir -p "${prefix}/bin"\ncp "${template}" "${prefix}/bin/brew"\nprintf update >> "${log}"\n`);
 const uninstaller=join(tmp,'uninstall.sh');
 writeFileSync(uninstaller,`[ "$1" = --path ] && [ "$2" = "${prefix}" ] || exit 33\nprintf removed >> "${log}"\n`+
   (failRemove?'exit 7\n':`rm "${prefix}/bin/brew"\nrmdir "${prefix}/bin" "${prefix}"\n`));
 executable(join(bin,'curl'),`for url do :; done
 case "$url" in
 */mac.sh) ${failDownload?'echo "touch '+tmp+'/bad"; exit 22':'cat "'+bootstrap+'"'} ;;
 */uninstall.sh) cat "${uninstaller}" ;;
 *) exit 88 ;; esac`);
 function run(command){return spawnSync(shell,['-c',`. "${script}"; ${command}`],{encoding:'utf8',env:{HOME:user,PATH:prefix+'/bin:'+bin+':/usr/bin:/bin',LANG:'C'}});}
 return {tmp,prefix,state,manager,run,log:()=>existsSync(log)?readFileSync(log,'utf8'):'',get:name=>readFileSync(join(manager,name),'utf8').trim(),put:(name,value)=>writeFileSync(join(manager,name),value)};
}
function ok(r){assert.equal(r.status,0,r.stderr);}
for(const shell of ['/bin/bash','/bin/zsh']){
 check(shell+' missing manager record: no writes or removal',()=>{const f=fixture(shell,{existing:true});ok(f.run('tex_remove_manager'));assert.equal(f.log(),'');assert.ok(!existsSync(f.manager));});
 check(shell+' fresh manager: full TeX install/remove then manager removal',()=>{const f=fixture(shell);ok(f.run('tex_install brew install --cask mactex'));assert.equal(f.get('baseline'),'absent');ok(f.run('tex_remove'));assert.ok(!existsSync(f.state));assert.ok(existsSync(f.manager));ok(f.run('tex_remove_manager'));assert.ok(!existsSync(f.manager));assert.ok(!existsSync(f.prefix));assert.match(f.log(),/removed/);});
 check(shell+' existing manager and its updates preserved',()=>{const f=fixture(shell,{existing:true});ok(f.run('tex_manager_prepare'));assert.equal(f.get('baseline'),'present');ok(f.run('tex_remove_manager'));assert.doesNotMatch(f.log(),/removed/);assert.ok(existsSync(join(f.prefix,'bin/brew')));});
 check(shell+' broken preexisting manager preserved',()=>{const f=fixture(shell,{broken:true});ok(f.run('tex_manager_prepare'));assert.equal(f.get('baseline'),'present');ok(f.run('tex_remove_manager'));assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' repeat bootstrap keeps new provenance',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));ok(f.run('tex_manager_prepare'));assert.equal(f.get('baseline'),'absent');ok(f.run('tex_remove_manager'));assert.match(f.log(),/removed/);});
 check(shell+' later package prevents removal and is not adopted on update',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));writeFileSync(join(f.prefix,'other-package'),'keep');assert.notEqual(f.run('tex_remove_manager').status,0);ok(f.run('tex_manager_prepare'));assert.equal(f.get('baseline'),'protected');ok(f.run('tex_remove_manager'));assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' TeX record must be removed first',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));mkdirSync(f.state);assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' incomplete download never executes or grants removal',()=>{const f=fixture(shell,{failDownload:true});assert.notEqual(f.run('tex_manager_prepare || exit 7').status,0);assert.ok(!existsSync(join(f.tmp,'bad')));assert.equal(f.get('status'),'pending');assert.notEqual(f.run('tex_remove_manager').status,0);});
 check(shell+' failed bootstrap stops even in OR context',()=>{const f=fixture(shell,{failBootstrap:true});assert.notEqual(f.run('tex_manager_prepare || exit 7').status,0);assert.ok(!existsSync(join(f.tmp,'bad')));assert.equal(f.get('status'),'pending');assert.notEqual(f.run('tex_manager_prepare').status,0);assert.notEqual(f.run('tex_remove_manager').status,0);});
 check(shell+' old TeX marker never grants manager ownership',()=>{const f=fixture(shell,{existing:true});mkdirSync(f.state,{recursive:true});writeFileSync(join(f.state,'manager'),'new');ok(f.run('tex_remove_manager'));assert.equal(f.log(),'');ok(f.run('tex_manager_prepare'));assert.equal(f.get('baseline'),'present');});
 check(shell+' wrong user rejected',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));f.put('user','999999');assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' unknown schema rejected',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));f.put('schema','old');assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' incomplete record not adopted',()=>{const f=fixture(shell);mkdirSync(f.manager,{recursive:true});f.put('after','unfinished');assert.notEqual(f.run('tex_manager_prepare').status,0);assert.notEqual(f.run('tex_remove_manager').status,0);assert.equal(f.log(),'');});
 check(shell+' record link rejected',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));unlinkSync(join(f.manager,'baseline'));symlinkSync(join(f.manager,'status'),join(f.manager,'baseline'));assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' concurrent operation rejected',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));mkdirSync(join(f.manager,'lock'));assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' changed prefix rejected',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare'));f.put('prefix','/');assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
 check(shell+' failed manufacturer removal keeps evidence',()=>{const f=fixture(shell,{failRemove:true});ok(f.run('tex_manager_prepare'));assert.notEqual(f.run('tex_remove_manager').status,0);assert.ok(existsSync(f.manager));});
 check(shell+' interrupted TeX operation blocks manager removal',()=>{const f=fixture(shell);ok(f.run('tex_manager_prepare; tex_manager_begin'));assert.equal(f.get('status'),'pending');assert.notEqual(f.run('tex_remove_manager').status,0);assert.doesNotMatch(f.log(),/removed/);});
}
console.log(count+' isolated Homebrew manager checks passed. No real package operations.');
rmSync(root,{recursive:true});
