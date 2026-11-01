# Candidate mutations occur in newly copied building releases, never in sealed
# facts or CDM tables. The enclosing fixture test checks the database marker.
testStoreRegressions <- function(details,schema,baseRelease,baseRun,execute,query) {
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);lit<-f('.store_literal')
 retainedRelease<-NULL
 for(i in 1:5) {
  run<-sprintf('20000000-0000-4000-8000-%012d',2*i);release<-sprintf('20000000-0000-4000-8000-%012d',2*i+1L)
  execute(paste0('INSERT INTO ',schema,'.achillesnext_analysis_run SELECT (jsonb_populate_record(NULL::',schema,'.achillesnext_analysis_run,to_jsonb(a)||jsonb_build_object(\'run_id\',',lit(run),'))).* FROM ',schema,'.achillesnext_analysis_run a WHERE run_id=',lit(baseRun)))
  execute(paste0('INSERT INTO ',schema,'.achillesnext_result_release VALUES (',lit(release),',',lit(run),",'building',142,0,null)"))
  for(table in c('achillesnext_dataset','achillesnext_aggregate_cell','achillesnext_denominator_edge'))execute(paste0('INSERT INTO ',schema,'.',table,' SELECT (jsonb_populate_record(NULL::',schema,'.',table,',to_jsonb(a)||jsonb_build_object(\'release_id\',',lit(release),'))).* FROM ',schema,'.',table,' a WHERE release_id=',lit(baseRelease)))
  where<-paste0(' release_id=',lit(release))
  if(i==4) {
   execute(paste0('UPDATE ',schema,".achillesnext_dataset SET state='suppressed',reason_code='fixture.policy_suppressed' WHERE ",where," AND metric_id='core.execution.output_status'"))
   execute(paste0('UPDATE ',schema,".achillesnext_aggregate_cell SET state='suppressed',reason_code='fixture.policy_suppressed',metadata_value=NULL WHERE ",where," AND metric_id='core.execution.output_status'"))
  } else if(i==5) {
   execute(paste0('UPDATE ',schema,".achillesnext_aggregate_cell SET state='suppressed',reason_code='fixture.policy_suppressed',metadata_value=NULL WHERE ",where," AND metric_id='core.execution.output_status' AND dimensions->>'metric_id'='core.person.count'"))
   expected<-'Missing ledger entry payload'
  } else if(i==1) {
   execute(paste0('DELETE FROM ',schema,'.achillesnext_aggregate_cell WHERE ',where," AND metric_id='core.measurement.numeric_summary' AND payload_kind='summary' AND n>0"))
   execute(paste0('UPDATE ',schema,'.achillesnext_dataset SET row_count=row_count-1 WHERE ',where," AND metric_id='core.measurement.numeric_summary'"))
   expected<-'Missing eligible summary'
  } else {
   mid<-if(i==2)'core.source.capabilities' else 'core.visit.care_setting_count';state<-if(i==2)'suppressed' else 'unsupported'
   execute(paste0('DELETE FROM ',schema,'.achillesnext_aggregate_cell WHERE ',where,' AND metric_id=',lit(mid)))
   execute(paste0('UPDATE ',schema,'.achillesnext_dataset SET state=',lit(state),",reason_code='fixture.missing',row_count=0",if(i==3)",conditional_support='{\"state\":\"schema_absent\",\"reason_code\":\"fixture.missing\"}'" else '', ' WHERE ',where,' AND metric_id=',lit(mid)))
   execute(paste0('UPDATE ',schema,".achillesnext_aggregate_cell SET metadata_value=jsonb_set(jsonb_set(metadata_value,'{state}',",lit(paste0('"',state,'"')),"::jsonb),'{reason_code}','\"fixture.missing\"'::jsonb) WHERE ",where," AND metric_id='core.execution.output_status' AND dimensions->>'metric_id'=",lit(mid)))
   expected<-if(i==2)'Capability inventory is required' else 'Required base marginals cannot be unsupported'
  }
  sealResultRelease(details,schema,release)
  if(i==4) {
   validateResultRelease(details,schema,release)
   stopifnot(query(paste0('SELECT state FROM ',schema,'.achillesnext_result_release WHERE release_id=',lit(release)))$STATE=='validated',
     query(paste0('SELECT count(*)::text AS n FROM ',schema,'.achillesnext_aggregate_cell WHERE release_id=',lit(release)," AND metric_id='core.execution.output_status' AND state='suppressed' AND metadata_value IS NULL"))$N=='142',
     query(paste0('SELECT count(*)::text AS n FROM ',schema,'.achillesnext_validation_receipt WHERE release_id=',lit(release)))$N=='1')
   retainedRelease<-release;next
  }
  message<-tryCatch({f('.store_transaction')(details,schema,function(tx)f('.store_validate')(tx,release));'ACCEPTED'},error=conditionMessage)
  stopifnot(message!='ACCEPTED',grepl(expected,message,fixed=TRUE))
  stopifnot(tryCatch({validateResultRelease(details,schema,release);FALSE},error=function(e)TRUE))
  stopifnot(query(paste0('SELECT count(*)::text AS n FROM ',schema,'.achillesnext_validation_receipt WHERE release_id=',lit(release)))$N=='0')
 }
 cat('PR16_SOURCE_ELIGIBILITY_CAPABILITY_AND_MARGINAL_REGRESSIONS_OK\n')
 cat('SUPPRESSED_LEDGER_RETAINED_ROWS_VALIDATE_WITHOUT_PAYLOAD_OK\n')
 invisible(retainedRelease)
}
