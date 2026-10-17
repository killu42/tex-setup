// Read the exported PDF, compare all copyable commands, then produce the native-test input.
import {readFileSync, writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const [source,pdf,pdftotext]=process.argv.slice(2);
const expected=[...readFileSync(source,'utf8').matchAll(/\\begin\{Befehl\}\n([\s\S]*?)\\end\{Befehl\}/g)].map(m=>m[1].trimEnd());
const text=execFileSync(pdftotext,['-layout',pdf,'-'],{encoding:'utf8'});
const names=['mac','intel','linux','windows','mac_remove','intel_remove','linux_remove','windows_remove'];
assert.equal(expected.length,names.length);
const commands={};
for(let i=0;i<names.length;i++) {
  const offset=text.indexOf(expected[i]);
  assert.ok(offset>=0,`PDF copy differs: ${names[i]}`);
  commands[names[i]]=text.slice(offset,offset+expected[i].length);
  assert.match(commands[names[i]],/^[\x09\x0a\x20-\x7e]+$/);
  console.log(`PASS PDF copy: ${names[i]}`);
}
writeFileSync(new URL('pdf-commands.json',import.meta.url),JSON.stringify(commands,null,2)+'\n');
