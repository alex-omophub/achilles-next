import {build} from 'vite';
import {builtinModules} from 'node:module';
import {fileURLToPath} from 'node:url';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root = fileURLToPath(new URL('../../../',import.meta.url));
await build({configFile:false,logLevel:'warn',build:{outDir:root+'inst/validation',emptyOutDir:true,target:'node22',minify:true,
  lib:{entry:fileURLToPath(new URL('./publication-validator.mjs',import.meta.url)),formats:['es'],fileName:()=> 'validate.mjs'},
  rollupOptions:{external:[...builtinModules,...builtinModules.map(m=>'node:'+m)]}}});
const sha256 = createHash('sha256').update(await readFile(root+'inst/validation/validate.mjs')).digest('hex');
await writeFile(root+'inst/validation/validator-lock.json',JSON.stringify({format_version:1,sha256},null,2)+'\n');
