// Headless conformance harness, NOT a browser viewer/mount implementation.
import {randomUUID} from 'node:crypto';
import {assertContext,sha256} from '../../src/index.mjs';
import {ensure,validateDocument} from '../../src/validator.mjs';
export function createHostHarness({provider,context,view,onEvent=()=>{},render=()=>{},cleanup=()=>{},instance_id=randomUUID(),correlation_id='mount'}) {
  let generation=0,closed=false,controller,options,destroyPromise;
  function emit(type,payload={},origin='system') {
    const event={contract_version:'1.0.0',event_id:randomUUID(),instance_id,generation,
      correlation_id:options.correlation_id,origin,context:structuredClone(options.context),type,payload};
    validateDocument('event',event);
    try {onEvent(event);} catch { /* Host observer errors do not own renderer lifetime. */ }
  }
  async function update(next) {
    ensure(!closed,'DESTROYED: instance is closed');validateDocument('context',next.context);
    options=structuredClone(next);const ownOptions=options,ownGeneration=++generation;
    controller?.abort();const currentController=new AbortController();controller=currentController;
    render(null); // Clear previous content immediately, including access-scope changes.
    const current=()=>!closed&&generation===ownGeneration;
    const superseded=()=>({status:closed?'destroyed':'superseded',generation:ownGeneration});
    const readOptions={signal:currentController.signal,requestId:`${instance_id}:${ownGeneration}`};
    try {
      const manifestBytes=await provider.getManifest(ownOptions.context,readOptions);
      if(!current()) return superseded();
      ensure(await sha256(manifestBytes)===ownOptions.context.manifest_sha256,'INTEGRITY_FAILURE: manifest bytes');
      if(!current()) return superseded();
      const manifest=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(manifestBytes));
      validateDocument('bundle',manifest);assertContext(manifest,ownOptions.context);
      const ids=ownOptions.view.kind==='metric'?[ownOptions.view.metric_id]:manifest.outputs.map(o=>o.metric_id);
      const results=await Promise.all(ids.map(async metricId=>{
        const bytes=await provider.getResult(ownOptions.context,metricId,readOptions);
        if(!current()) return null;
        const partition=manifest.outputs.find(p=>p.metric_id===metricId);ensure(partition,'NOT_REQUESTED: metric is outside manifest');
        ensure(await sha256(bytes)===partition.sha256&&String(bytes.length)===partition.bytes,'INTEGRITY_FAILURE: result bytes');
        if(!current()) return null;
        const result=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));validateDocument('result',result);assertContext(result,ownOptions.context);
        ensure(result.metric_id===metricId&&result.run_id===manifest.run_id&&result.request_sha256===manifest.request_sha256&&result.state===partition.state,'INCOMPATIBLE_CONTEXT: result provenance');
        return result;
      }));
      if(!current()) return superseded();
      render({context:ownOptions.context,manifest,results,generation:ownGeneration});emit('ready',{},'host');
      return {status:'applied',generation:ownGeneration};
    } catch(error) {
      if(!current()) return superseded();
      emit('error',{code:'PROVIDER_OR_CONTRACT_FAILURE',message:'Result access or contract validation failed.'});
      throw error;
    }
  }
  const instance={id:instance_id,ready:null,update,
    destroy() {
      if(destroyPromise) return destroyPromise;
      closed=true;generation++;controller?.abort();let renderError;
      try {render(null);} catch(error) {renderError=error;}
      emit('destroyed');
      destroyPromise=Promise.resolve().then(async()=>{await cleanup();if(renderError) throw renderError;});return destroyPromise;
    }};
  instance.ready=update({context,view,correlation_id});return instance;
}
