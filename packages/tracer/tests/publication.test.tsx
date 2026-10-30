import {readFile, readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {renderToStaticMarkup} from 'react-dom/server';
import {expect, it} from 'vitest';
import {openCountBundle, openServedCountBundle, type BundleFile} from '../src/file-provider';
import {CountView} from '../src/CountView';
const root = process.env.PUBLICATION_TEST_BUNDLES;
const signal = () => new AbortController().signal;
async function selected(scope: string) {
  const store = resolve(root!,scope), pointer = JSON.parse(await readFile(resolve(store,'current.json'),'utf8'));
  const folder = resolve(store,pointer.path), files = new Map<string,BundleFile>();
  for(const name of ['manifest.json','terminology.json',...(await readdir(resolve(folder,'results'))).map(n=>'results/'+n)]) {
    const bytes = await readFile(resolve(folder,name));
    files.set(name,{size:bytes.length,arrayBuffer:async()=>bytes.slice().buffer as ArrayBuffer});
  }
  return {folder,files};
}
it.runIf(!!root).each(['restricted','distributable'])('opens a complete %s release through file and served providers',async scope=>{
  const {folder,files} = await selected(scope);
  const r = await openCountBundle(files,signal());
  expect(r.count).toBe('4'); expect(r.manifest.publication).toBe('complete');
  expect(r.manifest.disclosure.scope).toBe(scope);
  const html = renderToStaticMarkup(<CountView result={r}/>);
  expect(html).toContain('Complete approved bundle');
  expect(html).not.toContain('remain unsupported');
  if(scope==='distributable') {
    expect(r.measurement!.documents.get('measurement.numeric_summary')).toMatchObject({state:'suppressed',rows:null});
    expect(r.measurement!.terminology.concepts).toEqual([]);
    expect(html).toContain('Suppressed'); expect(html).not.toContain('declared:fixture-1');
    expect(html).not.toContain('Exact monthly counts');
  } else expect(r.measurement!.documents.get('measurement.numeric_summary')!.rows!.length).toBeGreaterThan(0);
  const base = new URL('http://127.0.0.1:4000/nested/api/');
  const served = await openServedCountBundle(base,signal(),(async input=>{
    const name = new URL(String(input)).pathname.slice(base.pathname.length);
    return new Response(name==='status.json' ? '{"state":"ready"}' : await readFile(resolve(folder,name)));
  }) as typeof fetch);
  expect(served.context.manifest_sha256).toBe(r.context.manifest_sha256);
});
