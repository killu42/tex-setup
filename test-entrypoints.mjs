// Offline entry-point checks. Optional argument: the current .tex handout.
import {readFileSync,writeFileSync,mkdtempSync,mkdirSync,symlinkSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const dir=dirname(fileURLToPath(import.meta.url));
const root=mkdtempSync(join(tmpdir(),'tex-entry-tests-'));
const url='https://raw.githubusercontent.com/killu42/tex-setup/main/';
const mac='s=$(curl -fsSL '+url+'track.sh) && eval "$s" &&\ntex_install brew install --cask mactex';
const linux='u='+url+'linux-install.sh\n{ s=$(curl -fsSL "$u" 2>/dev/null) || s=$(wget -qO- "$u"); } && bash -c "$s"';
const removeMac='s=$(curl -fsSL '+url+'track.sh) &&\neval "$s" && tex_remove';
const removeLinux='u='+url+'track.sh\n{ s=$(curl -fsSL "$u" 2>/dev/null) || s=$(wget -qO- "$u"); } && eval "$s" && tex_remove';
let count=0;
function check(name,fn){fn();console.log('PASS '+name);count++;}
function fixture({os='Linux',noCurl=false,failCurl=false,failWget=false,failTracker=false,emptyTracker=false}={}){
 const tmp=mkdtempSync(join(root,'case-')),bin=join(tmp,'bin'),log=join(tmp,'calls'),partial=join(tmp,'partial');
 mkdirSync(bin);
 symlinkSync('/bin/bash',join(bin,'bash'));
 const mock=join(tmp,'tracker.sh');
 writeFileSync(mock,'tex_install() { printf "install %s\\n" "$*" >> "'+log+'"; }\ntex_remove() { printf "remove\\n" >> "'+log+'"; }\n');
 function executable(name,body){writeFileSync(join(bin,name),'#!/bin/bash\n'+body+'\n',{mode:0o755});}
 executable('uname','echo '+os);
 const partialOutput="printf 'touch \""+partial+"\";\\n'; exit 22";
 const download=fail=> [
   'for url do :; done',
   'if '+(fail?'true':'false')+'; then '+partialOutput+'; fi',
   'case "$url" in',
   ' */linux-install.sh) /bin/cat "'+join(dir,'linux-install.sh')+'" ;;',
   ' */track.sh) '+(failTracker?partialOutput:emptyTracker?':':'/bin/cat "'+mock+'"')+' ;;',
   ' *) exit 77 ;;',
   'esac'
 ].join('\n');
 if(!noCurl) executable('curl',download(failCurl));
 executable('wget',download(failWget));
 return {log,partial,run:(shell,command)=>spawnSync(shell,['-c',command],{encoding:'utf8',env:{PATH:bin,HOME:tmp,LANG:'C'}}),logged:()=>existsSync(log)?readFileSync(log,'utf8'):''};
}
for(const shell of ['/bin/bash','/bin/zsh']){
 check(shell+' two-line Mac install loader',()=>{const f=fixture({os:'Darwin'});const r=f.run(shell,mac);assert.equal(r.status,0,r.stderr);assert.equal(f.logged(),'install brew install --cask mactex\n');});
 check(shell+' failed Mac download never evaluates partial data',()=>{const f=fixture({failCurl:true});assert.notEqual(f.run(shell,mac).status,0);assert.equal(f.logged(),'');assert.equal(existsSync(f.partial),false);});
 check(shell+' Linux entry forwards exact tracked package list',()=>{const f=fixture();const r=f.run(shell,linux);assert.equal(r.status,0,r.stderr);assert.equal(f.logged(),'install sudo apt-get install -y texlive-latex-extra texlive-lang-german texlive-fonts-recommended biber latexmk texstudio\n');});
 check(shell+' Linux wget fallback without curl',()=>{const f=fixture({noCurl:true});const r=f.run(shell,linux);assert.equal(r.status,0,r.stderr);assert.match(f.logged(),/^install /);});
 check(shell+' partial first download is discarded, not concatenated',()=>{const f=fixture({failCurl:true});const r=f.run(shell,removeLinux);assert.equal(r.status,0,r.stderr);assert.equal(f.logged(),'remove\n');assert.equal(existsSync(f.partial),false);});
 check(shell+' both downloads fail without action',()=>{const f=fixture({failCurl:true,failWget:true});assert.notEqual(f.run(shell,linux).status,0);assert.equal(f.logged(),'');assert.equal(existsSync(f.partial),false);});
 check(shell+' Linux entry rejects incomplete tracker',()=>{const f=fixture({failTracker:true});assert.notEqual(f.run(shell,linux).status,0);assert.equal(f.logged(),'');assert.equal(existsSync(f.partial),false);});
 check(shell+' Linux entry rejects empty tracker',()=>{const f=fixture({emptyTracker:true});assert.notEqual(f.run(shell,linux).status,0);assert.equal(f.logged(),'');});
 check(shell+' Linux entry rejects other OS',()=>{const f=fixture({os:'Darwin'});assert.notEqual(f.run(shell,linux).status,0);assert.equal(f.logged(),'');});
 check(shell+' short Mac removal dispatch',()=>{const f=fixture({os:'Darwin'});const r=f.run(shell,removeMac);assert.equal(r.status,0,r.stderr);assert.equal(f.logged(),'remove\n');});
}
check('Linux entry Bash syntax',()=>assert.equal(spawnSync('/bin/bash',['-n',join(dir,'linux-install.sh')]).status,0));
if(process.argv[2]) check('all six PDF blocks match tested short forms and use ASCII',()=>{
 const source=readFileSync(process.argv[2],'utf8');
 const blocks=[...source.matchAll(/\\begin\{Befehl\}\n([\s\S]*?)\n\\end\{Befehl\}/g)].map(m=>m[1]);
 assert.deepEqual(blocks,[mac,linux,'irm '+url+'track.ps1 | iex\nInstall-TeX { winget install --id MiKTeX.MiKTeX -e --scope user -s winget }',removeMac,removeLinux,'irm '+url+'remove.ps1 | iex']);
 assert.ok(blocks.every(b=>/^[\x00-\x7f]*$/.test(b)));
 assert.equal(blocks.reduce((n,b)=>n+b.split('\n').length,0),11);
});
console.log(count+' isolated entry-point checks passed. No real package operations.');
