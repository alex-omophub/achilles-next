-- Aggregate store schema 2.0.0; installer substitutes quoted schema identifiers.
CREATE SCHEMA __STORE__;
CREATE SCHEMA __SERVE__;
REVOKE ALL ON SCHEMA __STORE__, __SERVE__ FROM PUBLIC;

CREATE DOMAIN __STORE__.sha256_hex AS text
  CHECK (VALUE ~ '^[0-9a-f]{64}$');
CREATE DOMAIN __STORE__.exact_decimal AS numeric
  CHECK (VALUE::text NOT IN ('NaN','Infinity','-Infinity'));
CREATE DOMAIN __STORE__.exact_count AS numeric
  CHECK (VALUE::text NOT IN ('NaN','Infinity','-Infinity') AND VALUE >= 0 AND VALUE = trunc(VALUE));

CREATE TABLE __STORE__.source_release (
  source_release_id uuid PRIMARY KEY,
  source_id text NOT NULL CHECK (octet_length(source_id) BETWEEN 1 AND 256),
  data_release_identity jsonb NOT NULL,
  vocabulary_identity jsonb NOT NULL,
  observed_schema_sha256 __STORE__.sha256_hex NOT NULL,
  declared_cdm_version text NOT NULL,
  captured_at timestamptz NOT NULL,
  CHECK (jsonb_typeof(data_release_identity)='object' AND octet_length(data_release_identity::text)<=65536),
  CHECK (jsonb_typeof(vocabulary_identity)='object' AND octet_length(vocabulary_identity::text)<=65536)
);
CREATE TABLE __STORE__.analysis_run (
  run_id uuid PRIMARY KEY,
  source_release_id uuid NOT NULL REFERENCES __STORE__.source_release,
  request_sha256 __STORE__.sha256_hex NOT NULL,
  profile_id text NOT NULL,
  profile_revision text NOT NULL,
  profile_sha256 __STORE__.sha256_hex NOT NULL,
  state text NOT NULL CHECK (state IN ('planned','running','cancel_requested','cancelled','failed','succeeded')),
  parent_run_id uuid REFERENCES __STORE__.analysis_run,
  consistency_basis text NOT NULL CHECK (consistency_basis IN ('unknown','single_repeatable_read','verified_immutable_source')),
  reusable_input_identity jsonb,
  started_at timestamptz,
  finished_at timestamptz,
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);
CREATE TABLE __STORE__.operation (
  run_id uuid NOT NULL REFERENCES __STORE__.analysis_run,
  operation_id text NOT NULL,
  definition_sha256 __STORE__.sha256_hex NOT NULL,
  state text NOT NULL CHECK (state IN ('planned','running','executed_uncommitted','succeeded','rolled_back','failed','cancelled','skipped')),
  dependency_ids jsonb NOT NULL CHECK (jsonb_typeof(dependency_ids)='array'),
  telemetry jsonb NOT NULL CHECK (jsonb_typeof(telemetry)='object'),
  PRIMARY KEY (run_id,operation_id)
);
CREATE TABLE __STORE__.result_release (
  release_id uuid PRIMARY KEY,
  run_id uuid NOT NULL UNIQUE REFERENCES __STORE__.analysis_run,
  state text NOT NULL CHECK (state IN ('building','sealed','validated','failed')),
  expected_metric_count integer NOT NULL CHECK (expected_metric_count > 0),
  content_revision bigint NOT NULL DEFAULT 0 CHECK (content_revision >= 0),
  sealed_at timestamptz
);
CREATE TABLE __STORE__.dataset (
  release_id uuid NOT NULL REFERENCES __STORE__.result_release,
  metric_id text NOT NULL CHECK (octet_length(metric_id)<=128),
  metric_version text NOT NULL,
  population_id text NOT NULL,
  grain_id text NOT NULL,
  row_schema_id text NOT NULL,
  definition_sha256 __STORE__.sha256_hex NOT NULL,
  state text NOT NULL CHECK (state IN ('computed','empty_source','empty_population','suppressed','unsupported','unavailable','inaccessible','failed','not_requested')),
  reason_code text,
  required boolean NOT NULL,
  conditional_support jsonb NOT NULL CHECK (jsonb_typeof(conditional_support)='object' AND octet_length(conditional_support::text)<=65536),
  row_count __STORE__.exact_count NOT NULL,
  completeness jsonb NOT NULL CHECK (jsonb_typeof(completeness)='object' AND octet_length(completeness::text)<=65536),
  PRIMARY KEY(release_id,metric_id),
  CHECK (state='computed' OR reason_code IS NOT NULL)
);
CREATE TABLE __STORE__.aggregate_cell (
  release_id uuid NOT NULL,
  metric_id text NOT NULL CHECK (octet_length(metric_id)<=128),
  row_key __STORE__.sha256_hex NOT NULL,
  route_key text COLLATE "C" NOT NULL CHECK (octet_length(route_key)<=512),
  sort_key text COLLATE "C" NOT NULL CHECK (octet_length(sort_key)<=1024),
  dimensions jsonb NOT NULL CHECK (jsonb_typeof(dimensions)='object' AND octet_length(dimensions::text) <= 65536),
  state text NOT NULL CHECK (state IN ('computed','empty_source','empty_population','suppressed','unsupported','unavailable')),
  reason_code text,
  payload_kind text NOT NULL CHECK (payload_kind IN ('counts','summary','metadata')),
  record_count __STORE__.exact_count,
  person_count __STORE__.exact_count,
  person_days __STORE__.exact_count,
  interval_count __STORE__.exact_count,
  n __STORE__.exact_count,
  sum_value __STORE__.exact_decimal,
  minimum __STORE__.exact_decimal,
  maximum __STORE__.exact_decimal,
  p10 __STORE__.exact_decimal,
  p25 __STORE__.exact_decimal,
  p50 __STORE__.exact_decimal,
  p75 __STORE__.exact_decimal,
  p90 __STORE__.exact_decimal,
  metadata_value jsonb,
  PRIMARY KEY(release_id,metric_id,row_key),
  UNIQUE(release_id,metric_id,route_key,sort_key),
  FOREIGN KEY(release_id,metric_id) REFERENCES __STORE__.dataset,
  CHECK (state='computed' OR reason_code IS NOT NULL),
  CHECK (
    (state IN ('suppressed','unsupported','unavailable') AND num_nonnulls(record_count,person_count,person_days,interval_count,n,sum_value,minimum,maximum,p10,p25,p50,p75,p90,metadata_value)=0)
    OR
    (state NOT IN ('suppressed','unsupported','unavailable') AND (
      (payload_kind='counts' AND num_nonnulls(record_count,person_count,person_days,interval_count)>0
        AND num_nonnulls(n,sum_value,minimum,maximum,p10,p25,p50,p75,p90,metadata_value)=0)
      OR
      (payload_kind='summary' AND n IS NOT NULL
        AND num_nonnulls(record_count,person_count,person_days,interval_count,metadata_value)=0
        AND ((n=0 AND num_nonnulls(sum_value,minimum,maximum,p10,p25,p50,p75,p90)=0)
          OR (n>0 AND num_nonnulls(sum_value,minimum,maximum,p10,p25,p50,p75,p90)=8
            AND minimum<=p10 AND p10<=p25 AND p25<=p50 AND p50<=p75 AND p75<=p90 AND p90<=maximum)))
      OR
      (payload_kind='metadata' AND metadata_value IS NOT NULL
        AND jsonb_typeof(metadata_value)='object' AND octet_length(metadata_value::text)<=65536
        AND num_nonnulls(record_count,person_count,person_days,interval_count,n,sum_value,minimum,maximum,p10,p25,p50,p75,p90)=0)
    ))
  )
) PARTITION BY HASH(metric_id);
DO $partitions$
BEGIN
  FOR i IN 0..7 LOOP
    EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES WITH (modulus 8, remainder %s)',
      '__STORE__.aggregate_cell_'||i, '__STORE__.aggregate_cell',i);
  END LOOP;
END
$partitions$;
CREATE TABLE __STORE__.denominator_edge (
  release_id uuid NOT NULL,
  metric_id text NOT NULL,
  row_key __STORE__.sha256_hex NOT NULL,
  measure_key text NOT NULL,
  target_metric_id text NOT NULL,
  target_row_key __STORE__.sha256_hex NOT NULL,
  target_measure_key text NOT NULL CHECK (target_measure_key IN ('record_count','person_count','person_days','interval_count','n')),
  PRIMARY KEY(release_id,metric_id,row_key,measure_key),
  FOREIGN KEY(release_id,metric_id,row_key) REFERENCES __STORE__.aggregate_cell,
  FOREIGN KEY(release_id,target_metric_id,target_row_key) REFERENCES __STORE__.aggregate_cell
);
CREATE TABLE __STORE__.validation_receipt (
  receipt_id uuid PRIMARY KEY,
  release_id uuid NOT NULL REFERENCES __STORE__.result_release,
  content_revision bigint NOT NULL,
  validator_version text NOT NULL,
  profile_sha256 __STORE__.sha256_hex NOT NULL,
  passed boolean NOT NULL,
  validated_at timestamptz NOT NULL,
  report_sha256 __STORE__.sha256_hex NOT NULL,
  UNIQUE(release_id,content_revision,receipt_id)
);
CREATE TABLE __STORE__.publication (
  publication_id uuid PRIMARY KEY,
  release_id uuid NOT NULL REFERENCES __STORE__.result_release,
  receipt_id uuid NOT NULL REFERENCES __STORE__.validation_receipt,
  scope_id text NOT NULL,
  disclosure_policy_sha256 __STORE__.sha256_hex NOT NULL,
  approval_id text NOT NULL,
  root_sha256 __STORE__.sha256_hex NOT NULL,
  state text NOT NULL CHECK (state IN ('building','ready','revoked')),
  prepared_at timestamptz NOT NULL,
  approved_at timestamptz,
  UNIQUE(publication_id,scope_id)
);
CREATE TABLE __STORE__.page_object (
  publication_id uuid NOT NULL REFERENCES __STORE__.publication,
  sha256 __STORE__.sha256_hex NOT NULL,
  kind text NOT NULL CHECK (kind IN ('root','index','metric_catalogue','concept_catalogue','terminology','data')),
  payload bytea NOT NULL CHECK (octet_length(payload) BETWEEN 2 AND 4194304),
  PRIMARY KEY(publication_id,sha256),
  CHECK (sha256=encode(pg_catalog.sha256(payload),'hex'))
);
CREATE TABLE __STORE__.audience_grant (
  scope_id text NOT NULL,
  database_role name NOT NULL,
  enabled boolean NOT NULL,
  PRIMARY KEY(scope_id,database_role)
);
CREATE TABLE __STORE__.current_publication (
  source_id text NOT NULL,
  profile_id text NOT NULL,
  scope_id text NOT NULL,
  publication_id uuid NOT NULL,
  revision bigint NOT NULL CHECK (revision>0),
  PRIMARY KEY(source_id,profile_id,scope_id),
  FOREIGN KEY(publication_id,scope_id) REFERENCES __STORE__.publication(publication_id,scope_id)
);

CREATE VIEW __SERVE__.approved_pages WITH (security_barrier=true) AS
 SELECT p.publication_id,s.source_id,a.profile_id,p.scope_id,p.root_sha256,o.sha256,o.kind,o.payload
 FROM __STORE__.publication p
 JOIN __STORE__.result_release r ON r.release_id=p.release_id
 JOIN __STORE__.analysis_run a ON a.run_id=r.run_id
 JOIN __STORE__.source_release s ON s.source_release_id=a.source_release_id
 JOIN __STORE__.validation_receipt v ON v.receipt_id=p.receipt_id
 JOIN __STORE__.audience_grant g ON g.scope_id=p.scope_id AND g.database_role=CURRENT_USER
 JOIN __STORE__.page_object o ON o.publication_id=p.publication_id
 WHERE p.state='ready' AND p.approval_id<>'' AND p.approved_at IS NOT NULL
   AND r.state='validated' AND v.passed AND v.release_id=r.release_id
   AND v.content_revision=r.content_revision AND v.profile_sha256=a.profile_sha256 AND g.enabled;
CREATE VIEW __SERVE__.approved_current WITH (security_barrier=true) AS
 SELECT c.source_id,c.profile_id,c.scope_id,c.publication_id,c.revision,p.root_sha256
 FROM __STORE__.current_publication c
 JOIN __STORE__.publication p ON p.publication_id=c.publication_id AND p.scope_id=c.scope_id
 JOIN __STORE__.result_release r ON r.release_id=p.release_id
 JOIN __STORE__.analysis_run a ON a.run_id=r.run_id
 JOIN __STORE__.source_release s ON s.source_release_id=a.source_release_id
 JOIN __STORE__.validation_receipt v ON v.receipt_id=p.receipt_id
 JOIN __STORE__.audience_grant g ON g.scope_id=c.scope_id AND g.database_role=CURRENT_USER
 WHERE p.state='ready' AND p.approved_at IS NOT NULL AND p.approval_id<>''
   AND r.state='validated' AND v.passed AND v.release_id=r.release_id
   AND v.content_revision=r.content_revision AND v.profile_sha256=a.profile_sha256
   AND c.source_id=s.source_id AND c.profile_id=a.profile_id AND g.enabled;

CREATE TABLE __STORE__.storage_version (
  version text PRIMARY KEY CHECK(version='2.0.0')
);
INSERT INTO __STORE__.storage_version VALUES ('2.0.0');

CREATE FUNCTION __STORE__.guard_building_release() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $guard$
DECLARE target uuid; current_state text;
BEGIN
 target := CASE WHEN TG_OP='DELETE' THEN OLD.release_id ELSE NEW.release_id END;
 IF TG_OP='UPDATE' AND NEW.release_id<>OLD.release_id THEN
   RAISE EXCEPTION 'Release identity is immutable';
 END IF;
 SELECT state INTO current_state FROM __STORE__.result_release WHERE release_id=target FOR UPDATE;
 IF current_state IS DISTINCT FROM 'building' THEN RAISE EXCEPTION 'Release is not writable'; END IF;
 UPDATE __STORE__.result_release SET content_revision=content_revision+1 WHERE release_id=target;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END
$guard$;
CREATE TRIGGER dataset_building BEFORE INSERT OR UPDATE OR DELETE ON __STORE__.dataset
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_building_release();
CREATE TRIGGER cell_building BEFORE INSERT OR UPDATE OR DELETE ON __STORE__.aggregate_cell
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_building_release();
CREATE TRIGGER denominator_building BEFORE INSERT OR UPDATE OR DELETE ON __STORE__.denominator_edge
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_building_release();

CREATE FUNCTION __STORE__.guard_release_transition() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $transition$
BEGIN
 IF NEW.release_id<>OLD.release_id OR NEW.run_id<>OLD.run_id OR NEW.expected_metric_count<>OLD.expected_metric_count THEN
  RAISE EXCEPTION 'Release identity and inventory are immutable';
 END IF;
 IF OLD.state<>'building' AND NEW.content_revision<>OLD.content_revision THEN
  RAISE EXCEPTION 'Sealed content revision is immutable';
 END IF;
 IF NEW.state<>OLD.state AND NOT ((OLD.state='building' AND NEW.state IN ('sealed','failed')) OR
    (OLD.state='sealed' AND NEW.state IN ('validated','failed'))) THEN
  RAISE EXCEPTION 'Invalid release transition';
 END IF;
 RETURN NEW;
END
$transition$;
CREATE TRIGGER release_transition BEFORE UPDATE ON __STORE__.result_release
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_release_transition();

CREATE FUNCTION __STORE__.seal_release(target uuid) RETURNS bigint
LANGUAGE plpgsql SET search_path=pg_catalog AS $seal$
DECLARE r __STORE__.result_release%ROWTYPE;
BEGIN
 SELECT * INTO STRICT r FROM __STORE__.result_release WHERE release_id=target FOR UPDATE;
 IF r.state<>'building' THEN RAISE EXCEPTION 'Release is not building'; END IF;
 IF (SELECT count(*) FROM __STORE__.dataset WHERE release_id=target)<>r.expected_metric_count THEN
  RAISE EXCEPTION 'Incomplete dataset inventory';
 END IF;
 IF EXISTS(SELECT 1 FROM __STORE__.dataset d WHERE d.release_id=target AND
   (d.row_count<>(SELECT count(*) FROM __STORE__.aggregate_cell c WHERE c.release_id=d.release_id AND c.metric_id=d.metric_id)
   OR (d.required AND d.state NOT IN ('computed','empty_source','empty_population','suppressed','unsupported')))) THEN
  RAISE EXCEPTION 'Dataset count or state prevents sealing';
 END IF;
 UPDATE __STORE__.result_release SET state='sealed',sealed_at=clock_timestamp() WHERE release_id=target;
 RETURN r.content_revision;
END
$seal$;

CREATE FUNCTION __STORE__.guard_receipt() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $receipt$
DECLARE r __STORE__.result_release%ROWTYPE; expected_hash text;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Validation receipts are append-only'; END IF;
 SELECT * INTO STRICT r FROM __STORE__.result_release WHERE release_id=NEW.release_id FOR SHARE;
 SELECT profile_sha256 INTO expected_hash FROM __STORE__.analysis_run WHERE run_id=r.run_id;
 IF r.state<>'sealed' OR NEW.content_revision<>r.content_revision OR NEW.profile_sha256<>expected_hash THEN
  RAISE EXCEPTION 'Receipt does not bind sealed content';
 END IF;
 RETURN NEW;
END
$receipt$;
CREATE TRIGGER receipt_bound BEFORE INSERT OR UPDATE OR DELETE ON __STORE__.validation_receipt
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_receipt();

CREATE FUNCTION __STORE__.guard_page_write() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $page$
DECLARE target uuid; current_state text;
BEGIN
 target := CASE WHEN TG_OP='DELETE' THEN OLD.publication_id ELSE NEW.publication_id END;
 IF TG_OP='UPDATE' AND NEW.publication_id<>OLD.publication_id THEN RAISE EXCEPTION 'Publication identity is immutable'; END IF;
 SELECT state INTO current_state FROM __STORE__.publication WHERE publication_id=target FOR UPDATE;
 IF current_state IS DISTINCT FROM 'building' THEN RAISE EXCEPTION 'Publication pages are immutable'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END
$page$;
CREATE TRIGGER page_building BEFORE INSERT OR UPDATE OR DELETE ON __STORE__.page_object
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_page_write();
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA __STORE__ FROM PUBLIC;

-- Installed numerical definitions are separate from execution/support claims.
CREATE TABLE __STORE__.profile_registry (
 profile_sha256 __STORE__.sha256_hex PRIMARY KEY,
 profile_id text NOT NULL,
 profile_revision text NOT NULL,
 definition_bytes bytea NOT NULL,
 definition jsonb NOT NULL,
 CHECK (profile_sha256=encode(pg_catalog.sha256(definition_bytes),'hex')),
 CHECK (definition=convert_from(definition_bytes,'UTF8')::jsonb),
 CHECK (jsonb_typeof(definition->'metrics')='array'),
 CHECK (definition->>'profile_id'=profile_id AND definition->>'revision'=profile_revision)
);

CREATE OR REPLACE FUNCTION __STORE__.guard_release_transition() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $transition$
DECLARE a __STORE__.analysis_run%ROWTYPE; p __STORE__.profile_registry%ROWTYPE;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.state<>'building' OR NEW.content_revision<>0 OR NEW.sealed_at IS NOT NULL THEN
   RAISE EXCEPTION 'New releases must start building';
  END IF;
  RETURN NEW;
 END IF;
 IF NEW.release_id<>OLD.release_id OR NEW.run_id<>OLD.run_id OR NEW.expected_metric_count<>OLD.expected_metric_count THEN
  RAISE EXCEPTION 'Release identity and inventory are immutable';
 END IF;
 IF OLD.state<>'building' AND (NEW.content_revision<>OLD.content_revision OR NEW.sealed_at IS DISTINCT FROM OLD.sealed_at) THEN
  RAISE EXCEPTION 'Sealed content revision is immutable';
 END IF;
 IF NEW.state<>OLD.state AND NOT ((OLD.state='building' AND NEW.state IN ('sealed','failed')) OR
    (OLD.state='sealed' AND NEW.state IN ('validated','failed'))) THEN
  RAISE EXCEPTION 'Invalid release transition';
 END IF;
 SELECT * INTO STRICT a FROM __STORE__.analysis_run WHERE run_id=NEW.run_id;
 IF NEW.state='sealed' AND OLD.state='building' THEN
  SELECT * INTO STRICT p FROM __STORE__.profile_registry WHERE profile_sha256=a.profile_sha256;
  IF a.profile_id<>p.profile_id OR a.profile_revision<>p.profile_revision OR
    NEW.expected_metric_count<>jsonb_array_length(p.definition->'metrics') OR NEW.sealed_at IS NULL THEN
   RAISE EXCEPTION 'Profile inventory mismatch';
  END IF;
  IF (SELECT count(*) FROM __STORE__.dataset WHERE release_id=NEW.release_id)<>NEW.expected_metric_count OR
    EXISTS(SELECT 1 FROM jsonb_array_elements(p.definition->'metrics') m
      LEFT JOIN __STORE__.dataset d ON d.release_id=NEW.release_id AND d.metric_id=m->>'id'
      WHERE d.metric_id IS NULL OR d.metric_version<>m->>'version' OR d.population_id<>m->>'population'
        OR d.grain_id<>m->>'grain' OR NOT d.required OR
        d.row_count<>(SELECT count(*) FROM __STORE__.aggregate_cell c WHERE c.release_id=d.release_id AND c.metric_id=d.metric_id)
        OR d.state NOT IN ('computed','empty_source','empty_population','suppressed','unsupported')
        OR (d.state='unsupported' AND (m->>'availability'='required_when_table_readable' OR d.conditional_support->>'state' IS DISTINCT FROM 'schema_absent')))
  THEN RAISE EXCEPTION 'Profile dataset inventory is incomplete'; END IF;
 END IF;
 IF NEW.state='validated' AND OLD.state='sealed' AND NOT EXISTS(
   SELECT 1 FROM __STORE__.validation_receipt v WHERE v.release_id=NEW.release_id
    AND v.content_revision=NEW.content_revision AND v.profile_sha256=a.profile_sha256 AND v.passed) THEN
   RAISE EXCEPTION 'Matching validation receipt required';
 END IF;
 RETURN NEW;
END
$transition$;
DROP TRIGGER release_transition ON __STORE__.result_release;
CREATE TRIGGER release_transition BEFORE INSERT OR UPDATE ON __STORE__.result_release
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_release_transition();

CREATE FUNCTION __STORE__.guard_publication_transition() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $publication$
DECLARE r __STORE__.result_release%ROWTYPE; v __STORE__.validation_receipt%ROWTYPE;
 a __STORE__.analysis_run%ROWTYPE; source_key text; root_doc jsonb;
BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.state<>'building' OR NEW.approved_at IS NOT NULL THEN RAISE EXCEPTION 'New publications must start building'; END IF;
  RETURN NEW;
 END IF;
 IF OLD.state<>'building' THEN
  IF (to_jsonb(NEW)-'state')<>(to_jsonb(OLD)-'state') OR
    (NEW.state<>OLD.state AND NOT (OLD.state='ready' AND NEW.state='revoked')) THEN
   RAISE EXCEPTION 'Approved publication is immutable';
  END IF;
  RETURN NEW;
 END IF;
 IF NEW.publication_id<>OLD.publication_id OR NEW.release_id<>OLD.release_id OR NEW.receipt_id<>OLD.receipt_id OR NEW.scope_id<>OLD.scope_id THEN
  RAISE EXCEPTION 'Publication identity is immutable';
 END IF;
 IF NEW.state='revoked' THEN RETURN NEW; END IF;
 IF NEW.state='ready' THEN
  SELECT * INTO STRICT r FROM __STORE__.result_release WHERE release_id=NEW.release_id FOR SHARE;
  SELECT * INTO STRICT a FROM __STORE__.analysis_run WHERE run_id=r.run_id;
  SELECT * INTO STRICT v FROM __STORE__.validation_receipt WHERE receipt_id=NEW.receipt_id;
  SELECT source_id INTO STRICT source_key FROM __STORE__.source_release WHERE source_release_id=a.source_release_id;
  IF r.state<>'validated' OR NOT v.passed OR v.release_id<>r.release_id OR
    v.content_revision<>r.content_revision OR v.profile_sha256<>a.profile_sha256 OR
    NEW.approved_at IS NULL OR NEW.approval_id='' THEN RAISE EXCEPTION 'Publication is not validated and approved'; END IF;
  SELECT convert_from(payload,'UTF8')::jsonb INTO STRICT root_doc FROM __STORE__.page_object
   WHERE publication_id=NEW.publication_id AND sha256=NEW.root_sha256 AND kind='root' AND octet_length(payload)<=262144;
  IF root_doc->>'contract_version' IS DISTINCT FROM '2.0.0' OR
    root_doc->>'publication_id' IS DISTINCT FROM NEW.publication_id::text OR
    root_doc->>'release_id' IS DISTINCT FROM r.release_id::text OR
    root_doc->>'source_id' IS DISTINCT FROM source_key OR
    root_doc->>'profile_id' IS DISTINCT FROM a.profile_id OR
    root_doc->>'profile_revision' IS DISTINCT FROM a.profile_revision OR
    root_doc->>'profile_sha256' IS DISTINCT FROM a.profile_sha256 OR
    root_doc->>'access_scope_id' IS DISTINCT FROM NEW.scope_id OR
    root_doc->'eligible_for_current_pointer' IS DISTINCT FROM 'true'::jsonb OR
    root_doc->>'publication_state' IS DISTINCT FROM 'ready' THEN RAISE EXCEPTION 'Root context is not publishable'; END IF;
 END IF;
 RETURN NEW;
END
$publication$;
CREATE TRIGGER publication_transition BEFORE INSERT OR UPDATE ON __STORE__.publication
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_publication_transition();

-- The pointer invariant also applies to direct DML by a trusted publisher.
CREATE FUNCTION __STORE__.guard_current_pointer() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $pointer$
DECLARE p __STORE__.publication%ROWTYPE; r __STORE__.result_release%ROWTYPE;
 a __STORE__.analysis_run%ROWTYPE; source_key text;
BEGIN
 IF TG_OP='UPDATE' AND (NEW.source_id<>OLD.source_id OR NEW.profile_id<>OLD.profile_id OR NEW.scope_id<>OLD.scope_id OR NEW.revision<>OLD.revision+1) THEN
  RAISE EXCEPTION 'Invalid current pointer revision';
 END IF;
 IF TG_OP='INSERT' AND NEW.revision<>1 THEN RAISE EXCEPTION 'Initial pointer revision must be one'; END IF;
 SELECT * INTO STRICT p FROM __STORE__.publication WHERE publication_id=NEW.publication_id FOR SHARE;
 SELECT * INTO STRICT r FROM __STORE__.result_release WHERE release_id=p.release_id FOR SHARE;
 SELECT * INTO STRICT a FROM __STORE__.analysis_run WHERE run_id=r.run_id;
 SELECT source_id INTO STRICT source_key FROM __STORE__.source_release WHERE source_release_id=a.source_release_id;
 IF p.state<>'ready' OR r.state<>'validated' OR p.scope_id<>NEW.scope_id OR source_key<>NEW.source_id OR a.profile_id<>NEW.profile_id THEN
  RAISE EXCEPTION 'Current pointer context mismatch';
 END IF;
 RETURN NEW;
END
$pointer$;
CREATE TRIGGER current_context BEFORE INSERT OR UPDATE ON __STORE__.current_publication
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_current_pointer();

CREATE FUNCTION __STORE__.promote_publication(target uuid, expected_revision bigint) RETURNS bigint
LANGUAGE plpgsql SET search_path=pg_catalog AS $promote$
DECLARE p __STORE__.publication%ROWTYPE; a __STORE__.analysis_run%ROWTYPE;
 source_key text; current_row __STORE__.current_publication%ROWTYPE; actual_revision bigint;
BEGIN
 IF expected_revision<0 OR expected_revision IS NULL THEN RAISE EXCEPTION 'Invalid expected revision'; END IF;
 SELECT * INTO STRICT p FROM __STORE__.publication WHERE publication_id=target FOR SHARE;
 SELECT ar.* INTO STRICT a FROM __STORE__.analysis_run ar JOIN __STORE__.result_release rr ON rr.run_id=ar.run_id WHERE rr.release_id=p.release_id;
 SELECT source_id INTO STRICT source_key FROM __STORE__.source_release WHERE source_release_id=a.source_release_id;
 IF p.state<>'ready' THEN RAISE EXCEPTION 'Publication is not ready'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(source_key,a.profile_id,p.scope_id)::text,0));
 SELECT * INTO current_row FROM __STORE__.current_publication WHERE source_id=source_key AND profile_id=a.profile_id AND scope_id=p.scope_id FOR UPDATE;
 actual_revision:=COALESCE(current_row.revision,0);
 IF current_row.publication_id=target THEN RETURN actual_revision; END IF;
 IF actual_revision<>expected_revision THEN RAISE EXCEPTION 'Current publication conflict'; END IF;
 IF actual_revision=0 THEN
  INSERT INTO __STORE__.current_publication VALUES(source_key,a.profile_id,p.scope_id,target,1);
 ELSE
  UPDATE __STORE__.current_publication SET publication_id=target,revision=actual_revision+1
   WHERE source_id=source_key AND profile_id=a.profile_id AND scope_id=p.scope_id;
 END IF;
 RETURN actual_revision+1;
END
$promote$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA __STORE__ FROM PUBLIC;

CREATE FUNCTION __STORE__.guard_source_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $source_identity$
BEGIN RAISE EXCEPTION 'Source release assertions are immutable'; END
$source_identity$;
CREATE TRIGGER source_identity BEFORE UPDATE OR DELETE ON __STORE__.source_release
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_source_identity();
CREATE FUNCTION __STORE__.guard_run_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $run_identity$
BEGIN
 IF NEW.state<>OLD.state AND NOT (
   (OLD.state='planned' AND NEW.state IN ('running','cancelled','failed')) OR
   (OLD.state='running' AND NEW.state IN ('cancel_requested','cancelled','failed','succeeded')) OR
   (OLD.state='cancel_requested' AND NEW.state IN ('cancelled','failed'))) THEN
  RAISE EXCEPTION 'Invalid run state transition';
 END IF;
 IF (to_jsonb(NEW)-ARRAY['state','started_at','finished_at'])<>(to_jsonb(OLD)-ARRAY['state','started_at','finished_at']) THEN
  RAISE EXCEPTION 'Run identity is immutable';
 END IF;
 RETURN NEW;
END
$run_identity$;
CREATE TRIGGER run_identity BEFORE UPDATE ON __STORE__.analysis_run
 FOR EACH ROW EXECUTE FUNCTION __STORE__.guard_run_identity();
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA __STORE__ FROM PUBLIC;
