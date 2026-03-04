-- =============================================================================
-- ADS-B HISTORICAL BACKFILL (adsb.lol globe_history)
-- Database: ${DATABASE}.${SCHEMA}
-- Source: https://github.com/adsblol/globe_history
-- License: ODbL 1.0
-- =============================================================================

-- =============================================================================
-- ADSB.LOL HISTORICAL BACKFILL
-- Source: adsb.lol globe_history (GitHub releases)
-- https://github.com/adsblol/globe_history
-- License: ODbL 1.0
-- =============================================================================

-- -----------------------------------------------------------------------------
-- External Network Access (for GitHub API, adsb.lol, and aircraft lookup)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE ${DATABASE}.${SCHEMA}.${SCHEMA}_github_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.github.com:443', 'github.com:443', 'objects.githubusercontent.com:443', 'release-assets.githubusercontent.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${EAI_GITHUB}
  ALLOWED_NETWORK_RULES = (${DATABASE}.${SCHEMA}.${SCHEMA}_github_rule)
  ENABLED = TRUE;



-- =============================================================================
-- STAGE-BASED HISTORICAL ADS-B DATA PIPELINE (SQL-optimized)
-- Downloads TAR files to internal stage, extracts to NDJSON, 
-- then uses SQL FLATTEN + ST_DWITHIN for parallel filtering
-- =============================================================================

-- Internal stage for downloaded TAR files and extracted NDJSON
CREATE STAGE IF NOT EXISTS ${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE;

-- Tracking table for backfill status
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS (
    data_date DATE PRIMARY KEY,
    download_status VARCHAR(20) DEFAULT 'pending',
    downloaded_at TIMESTAMP_NTZ,
    extracted_at TIMESTAMP_NTZ,
    loaded_at TIMESTAMP_NTZ,
    processed_at TIMESTAMP_NTZ,
    downloaded_parts INT,
    downloaded_bytes NUMBER(38,0),
    aircraft_extracted INT,
    rows_loaded INT,
    aircraft_found INT,
    points_inserted INT,
    error_message VARCHAR(500)
);

-- Backward/forward compatible schema upgrades
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS loaded_at TIMESTAMP_NTZ;
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS downloaded_parts INT;
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS downloaded_bytes NUMBER(38,0);
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS rows_loaded INT;

-- Interim table for raw aircraft JSON (one row per aircraft)
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM (
    data_date DATE,
    raw_json VARIANT,
    loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- Procedure: Download TAR files to internal stage
-- Downloads split TAR parts from globe_history_YYYY to stage for later processing
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_DOWNLOAD_TO_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'download_to_stage'
EXTERNAL_ACCESS_INTEGRATIONS = (${EAI_GITHUB})
AS
$$
import requests
from datetime import datetime
from io import BytesIO
import string

def download_to_stage(session, p_date):
    '''Download TAR parts from adsb.lol to internal stage.'''
    try:
        date_obj = datetime.strptime(p_date, '%Y-%m-%d')
        year = date_obj.year
        date_dot = date_obj.strftime('%Y.%m.%d')
    except:
        return f"Invalid date: {p_date}"
    
    # Tag formats have changed over time; try a small set of known patterns.
    # NOTE: If the GitHub repo for the computed year doesn't exist yet (or a tag doesn't exist),
    # the first request will 404. We treat that as "try next tag".
    tags_to_try = [
        f"v{date_dot}-planes-readsb-prod-0",
        f"v{date_dot}-planes-readsb-prod",
        f"v{date_dot}-planes-readsb-prod-1",
    ]
    stage_path = f"@${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/{p_date}"
    
    # Suffixes are .tar.aa, .tar.ab, ... continue until 404
    suffixes = [a + b for a in string.ascii_lowercase for b in string.ascii_lowercase]

    chosen_tag = None
    parts_downloaded = 0
    total_bytes = 0
    saw_404 = False
    incomplete_err = None

    for tag in tags_to_try:
        base_url = f"https://github.com/adsblol/globe_history_{year}/releases/download/{tag}"

        # Resume-safe: skip parts that already exist on stage for this tag
        existing_suffixes = set()
        try:
            existing = session.sql(f"LIST {stage_path} PATTERN='.*{tag}\\\\.tar\\\\..*'").collect()
            for row in existing or []:
                try:
                    name = str(row[0])
                    size = int(row[1]) if row[1] is not None else 0
                    total_bytes += size
                    parts_downloaded += 1
                    existing_suffixes.add(name.split('.tar.')[-1])
                except Exception:
                    continue
        except Exception:
            existing_suffixes = set()

        # Try downloading missing parts for this tag
        saw_404 = False
        incomplete_err = None
        started_any = False

        for suffix in suffixes:
            if suffix in existing_suffixes:
                continue
            part_url = f"{base_url}/{tag}.tar.{suffix}"
            stage_file = f"{stage_path}/{tag}.tar.{suffix}"

            try:
                with requests.get(part_url, stream=True, timeout=600) as resp:
                    if resp.status_code == 404:
                        saw_404 = True
                        break
                    if resp.status_code in (401, 403, 429):
                        incomplete_err = f"HTTP {resp.status_code}"
                        break
                    if resp.status_code != 200:
                        continue

                    started_any = True
                    # Prefer true streaming: avoid buffering multi-GB parts in memory.
                    try:
                        if hasattr(resp, "raw") and resp.raw is not None:
                            try:
                                resp.raw.decode_content = False
                            except Exception:
                                pass
                            session.file.put_stream(resp.raw, stage_file, auto_compress=False, overwrite=True)
                            cl = resp.headers.get("Content-Length")
                            if cl and str(cl).isdigit():
                                total_bytes += int(cl)
                        else:
                            raise Exception("resp.raw not available")
                    except Exception:
                        buffer = BytesIO()
                        for chunk in resp.iter_content(chunk_size=10*1024*1024):
                            if not chunk:
                                continue
                            buffer.write(chunk)
                        buffer.seek(0)
                        total_bytes += buffer.getbuffer().nbytes
                        session.file.put_stream(buffer, stage_file, auto_compress=False, overwrite=True)

                parts_downloaded += 1
            except Exception as e:
                incomplete_err = str(e)[:200]
                break

        # If split TAR parts don't exist for this tag (404 on first part), try single-file artifacts.
        # Some days/tags may publish a single .tar.gz (or .tar) instead of split .tar.aa parts.
        if (parts_downloaded == 0) and saw_404 and (not started_any) and (not (incomplete_err and incomplete_err.startswith("HTTP "))):
            for ext in (".tar.gz", ".tgz", ".tar"):
                # NOTE: This code runs inside the Snowflake Python proc. Escape braces so the
                # installer's outer f-string doesn't try to evaluate base_url/tag/ext.
                one_url = f"{base_url}/{tag}{ext}"
                one_dest = f"{stage_path}/{tag}{ext}"
                try:
                    with requests.get(one_url, stream=True, timeout=600) as resp:
                        if resp.status_code == 404:
                            continue
                        if resp.status_code in (401, 403, 429):
                            # Escape braces so the installer's outer f-string doesn't evaluate `resp`.
                            incomplete_err = f"HTTP {resp.status_code}"
                            break
                        if resp.status_code != 200:
                            continue

                        try:
                            if hasattr(resp, "raw") and resp.raw is not None:
                                try:
                                    resp.raw.decode_content = False
                                except Exception:
                                    pass
                                session.file.put_stream(resp.raw, one_dest, auto_compress=False, overwrite=True)
                                cl = resp.headers.get("Content-Length")
                                if cl and str(cl).isdigit():
                                    total_bytes += int(cl)
                            else:
                                raise Exception("resp.raw not available")
                        except Exception:
                            buffer = BytesIO()
                            for chunk in resp.iter_content(chunk_size=10*1024*1024):
                                if not chunk:
                                    continue
                                buffer.write(chunk)
                            buffer.seek(0)
                            total_bytes += buffer.getbuffer().nbytes
                            session.file.put_stream(buffer, one_dest, auto_compress=False, overwrite=True)

                    parts_downloaded += 1
                    chosen_tag = tag
                    saw_404 = True  # treat as complete artifact
                    break
                except Exception as e:
                    incomplete_err = str(e)[:200]
                    break

            if chosen_tag:
                break

        # If we downloaded anything (or had existing parts), lock onto this tag.
        if parts_downloaded > 0:
            chosen_tag = tag
            break

        # If we got throttled/forbidden, stop early and record failure.
        if incomplete_err and incomplete_err.startswith("HTTP "):
            break

        # If we never saw a 404 and never downloaded anything, try next tag anyway.
        # If we DID see 404 immediately (first suffix), this tag likely doesn't exist; try next tag.
        continue
    
    if parts_downloaded == 0:
        # Distinguish "no release yet" from "blocked/throttled" (403/429).
        if incomplete_err and incomplete_err.startswith("HTTP "):
            try:
                session.sql(f'''
                    MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
                    USING (SELECT '{p_date}'::DATE AS data_date) s ON t.data_date = s.data_date
                    WHEN MATCHED THEN UPDATE SET download_status = 'failed', error_message = 'GitHub download blocked: {incomplete_err}'
                    WHEN NOT MATCHED THEN INSERT (data_date, download_status, error_message)
                      VALUES (s.data_date, 'failed', 'GitHub download blocked: {incomplete_err}')
                ''').collect()
            except Exception:
                pass
            return f"Download blocked: {incomplete_err}"

        # Most commonly: the daily release for this date isn't published yet (e.g., "today").
        # Track as "not_available_yet" so an automated retry can pick it up later.
        try:
            session.sql(f'''
                MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
                USING (SELECT '{p_date}'::DATE AS data_date) s ON t.data_date = s.data_date
                WHEN MATCHED THEN UPDATE SET
                  download_status = IFF(LOWER(t.download_status) IN ('extracted','loaded','processed'), t.download_status, 'not_available_yet'),
                  error_message = IFF(
                    LOWER(t.download_status) IN ('extracted','loaded','processed'),
                    error_message,
                    'No TAR parts found (release not published yet?)'
                  )
                WHEN NOT MATCHED THEN INSERT (data_date, download_status, error_message)
                  VALUES (s.data_date, 'not_available_yet', 'No TAR parts found (release not published yet?)')
            ''').collect()
        except Exception:
            pass
        return f"No TAR parts found for {p_date}"

    # Only mark fully "downloaded" when we see the first 404 (end-of-parts).
    # Otherwise, treat as partial/incomplete so downstream steps don't try to extract a truncated TAR.
    status = 'downloaded' if saw_404 else 'downloaded_partial'
    err_msg = (incomplete_err or '')
    try:
        session.sql(f'''
            MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
            USING (SELECT '{p_date}'::DATE AS data_date) s ON t.data_date = s.data_date
            WHEN MATCHED THEN UPDATE SET 
                -- IMPORTANT: never downgrade status once a later stage has completed.
                download_status = IFF(LOWER(t.download_status) IN ('extracted','loaded','processed'), t.download_status, '{status}'),
                downloaded_at = CURRENT_TIMESTAMP(),
                downloaded_parts = {parts_downloaded},
                downloaded_bytes = {total_bytes},
                error_message = IFF(
                    LOWER(t.download_status) IN ('extracted','loaded','processed'),
                    error_message,
                    IFF('{status}' = 'downloaded_partial', LEFT('{err_msg}', 200), error_message)
                )
            WHEN NOT MATCHED THEN INSERT (data_date, download_status, downloaded_at, downloaded_parts, downloaded_bytes, error_message) 
                VALUES (s.data_date, '{status}', CURRENT_TIMESTAMP(), {parts_downloaded}, {total_bytes}, IFF('{status}' = 'downloaded_partial', LEFT('{err_msg}', 200), NULL))
        ''').collect()
    except Exception:
        pass

    if status == 'downloaded_partial':
        return f"Partial download: {parts_downloaded} parts ({total_bytes/1024/1024:.1f} MB) to {stage_path}. Retry to continue."
    return f"Downloaded {parts_downloaded} parts ({total_bytes/1024/1024:.1f} MB) to {stage_path}"
$$;

-- =============================================================================
-- Procedure: Extract TAR to batched NDJSON on stage (STREAMING)
-- PERFORMANCE: reduces stage writes from ~50k/day to ~tens/day
-- NOTE: We still avoid JSON parsing; we only gzip-decompress each trace file to get JSON bytes
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_EXTRACT_TO_NDJSON(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'extract_to_stage'
AS
$$
import tarfile
from io import BytesIO
from snowflake.snowpark.files import SnowflakeFile
import os
import gzip

class ChainedFiles:
    '''Chain multiple file objects into one seamless stream.'''
    def __init__(self, file_handles):
        self.files = iter(file_handles)
        self.current = next(self.files, None)
    
    def read(self, n=-1):
        if self.current is None:
            return b''
        chunks = []
        remaining = n
        while self.current is not None and (remaining != 0):
            data = self.current.read(remaining if remaining > 0 else -1)
            if not data:
                self.current = next(self.files, None)
            else:
                chunks.append(data)
                if remaining > 0:
                    remaining -= len(data)
        return b''.join(chunks)
    
    def close(self):
        if self.current:
            try: self.current.close()
            except: pass
        for f in self.files:
            try: f.close()
            except: pass

def extract_to_stage(session, p_date):
    '''Extract TAR and write batched NDJSON (.ndjson.gz) files to stage.
    
    STREAMING MODE:
    - Chains TAR parts without loading all into memory
    - Reads each member content immediately (required for streaming)
    - Buffers only one trace file at a time (+ one batch buffer)
    
    OUTPUT:
      @<database>.<schema>.ADSB_HISTORY_STAGE/<p_date>/ndjson/batch_0001.ndjson.gz
      @<database>.<schema>.ADSB_HISTORY_STAGE/<p_date>/ndjson/batch_0002.ndjson.gz
      ...
    '''
    stage_path = f"@${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/{p_date}"
    
    try:
        files_result = session.sql(f"LIST {stage_path}").collect()
        if not files_result:
            return f"No files found in stage for {p_date}"
    except Exception as e:
        return f"Error listing stage: {str(e)[:100]}"
    
    # Only process .tar files, skip extracted traces
    tar_files = sorted([f"@${DATABASE}.${SCHEMA}.{row[0]}" for row in files_result 
                       if '.tar.' in row[0] and '/traces/' not in row[0]])
    
    if not tar_files:
        return f"No TAR files found for {p_date}"

    ndjson_dir = f"@${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/"
    # Smart resume:
    # - If NDJSON batches already exist AND status indicates extracted/loaded/processed, skip extraction.
    # - If batches exist but status does not, treat as partial and restart extraction for this day.
    try:
        existing_batches = session.sql(f"LIST {ndjson_dir} PATTERN='.*\\\\.ndjson\\\\.gz'").collect()
    except Exception:
        existing_batches = []

    if existing_batches:
        try:
            st = session.sql(f'''
                SELECT download_status, extracted_at
                FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                WHERE data_date = '{p_date}'::DATE
                LIMIT 1
            ''').collect()
            if st:
                status = (st[0][0] or '').lower()
                extracted_at = st[0][1]
                if status in ('extracted', 'loaded', 'processed') and extracted_at is not None:
                    return f"Already extracted (found {len(existing_batches)} NDJSON batches) in {ndjson_dir}"
        except Exception:
            pass

        # Partial/unknown state: restart this day (safe, deterministic)
        try:
            session.sql(f"REMOVE {ndjson_dir};").collect()
        except Exception:
            pass
    
    # Open all TAR parts as file handles
    file_handles = []
    for file_path in tar_files:
        try:
            fh = SnowflakeFile.open(file_path, 'rb', require_scoped_url=False)
            file_handles.append(fh)
        except Exception as e:
            for h in file_handles:
                try: h.close()
                except: pass
            return f"Error opening {file_path}: {str(e)[:200]}"
    
    if not file_handles:
        return f"No TAR files could be opened for {p_date}"
    
    chained = ChainedFiles(file_handles)
    aircraft_written = 0
    skipped = 0

    # Tuning knobs (favor stability and fewer stage writes)
    min_member_bytes = 1024          # skip very small compressed members (likely empty stubs)
    batch_max_aircraft = 2000        # flush after N aircraft JSON objects
    batch_max_compressed_bytes = 64 * 1024 * 1024  # flush when gzip buffer exceeds ~64MB

    batch_idx = 1
    batch_buf = BytesIO()
    gz_out = gzip.GzipFile(fileobj=batch_buf, mode='wb')

    def flush_batch():
        nonlocal batch_idx, batch_buf, gz_out
        gz_out.close()
        batch_buf.seek(0)
        dest = f"@${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/batch_{batch_idx:04d}.ndjson.gz"
        session.file.put_stream(batch_buf, dest, auto_compress=False, overwrite=True)
        batch_idx += 1
        batch_buf = BytesIO()
        gz_out = gzip.GzipFile(fileobj=batch_buf, mode='wb')
    
    try:
        # Streaming mode 'r|*' - must read member content immediately
        with tarfile.open(fileobj=chained, mode='r|*') as tar:
            for member in tar:
                name = member.name
                
                # Skip non-trace files - accept both .json and .json.gz
                if (name.startswith('./heatmap') or 
                    name.startswith('./acas') or 
                    name.startswith('./LICENSE') or 
                    name.startswith('./README') or
                    'trace_full_' not in name or 
                    not (name.endswith('.json') or name.endswith('.json.gz'))):
                    skipped += 1
                    continue
                
                # Heuristic: extremely small members are almost always empty traces/stubs
                try:
                    if int(getattr(member, 'size', 0) or 0) < min_member_bytes:
                        skipped += 1
                        continue
                except Exception:
                    pass

                f = tar.extractfile(member)
                if f is None:
                    continue
                
                # CRITICAL: In streaming mode, must read content IMMEDIATELY
                # before iterating to next member
                raw_bytes = f.read()

                # Files are commonly gzipped even when the extension is .json.
                # We avoid JSON parsing; just decompress to raw JSON bytes, then write NDJSON line.
                try:
                    json_bytes = gzip.decompress(raw_bytes)
                except Exception:
                    json_bytes = raw_bytes

                # Write one JSON object per line (NDJSON)
                gz_out.write(json_bytes.strip())
                # IMPORTANT: write newline as a byte without using a backslash escape in this embedded code.
                gz_out.write(bytes([10]))
                aircraft_written += 1

                # Flush periodically to keep memory bounded and reduce stage writes
                if (aircraft_written % batch_max_aircraft) == 0:
                    flush_batch()
                elif batch_buf.tell() >= batch_max_compressed_bytes:
                    flush_batch()
    
    except Exception as e:
        return f"TAR error: {str(e)[:200]}"
    finally:
        try:
            # flush remaining
            if aircraft_written % batch_max_aircraft != 0 and batch_buf.tell() > 0:
                flush_batch()
        except Exception:
            pass
        chained.close()
    
    if aircraft_written == 0:
        try:
            session.sql(f'''
                MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
                USING (SELECT '{p_date}'::DATE AS data_date) s ON t.data_date = s.data_date
                WHEN MATCHED THEN UPDATE SET download_status = 'extract_failed', error_message = 'No aircraft traces extracted', extracted_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT (data_date, download_status, error_message, extracted_at)
                    VALUES (s.data_date, 'extract_failed', 'No aircraft traces extracted', CURRENT_TIMESTAMP())
            ''').collect()
        except Exception:
            pass
        return f"No aircraft traces extracted for {p_date}"
    
    # Update status
    try:
        session.sql(f'''
            UPDATE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS 
            SET download_status = 'extracted', 
                extracted_at = CURRENT_TIMESTAMP(),
                aircraft_extracted = {aircraft_written}
            WHERE data_date = '{p_date}'
        ''').collect()
    except:
        pass
    
    return f"Extracted {aircraft_written} aircraft traces to NDJSON batches (streaming, skipped {skipped} aux files)"
$$;

-- =============================================================================
-- Procedure: Load individual JSON files to interim table
-- Uses COPY INTO with COMPRESSION=AUTO - Snowflake handles gzip decompression
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_LOAD_NDJSON_TO_INTERIM(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'load_json_files'
AS
$$
def load_json_files(session, p_date):
    '''Load batched NDJSON (.ndjson.gz) files using COPY INTO.
    
    Snowflake handles gzip decompression and JSON parsing; each NDJSON line becomes one VARIANT row.
    '''
    # Clear any existing data for this date
    session.sql(f"DELETE FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = '{p_date}'").collect()
    
    stage_dir = f"@${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/"

    try:
        listed = session.sql(f"LIST {stage_dir} PATTERN='.*\\\\.ndjson\\\\.gz'").collect()
    except Exception as e:
        return f"Error listing ndjson batches: {str(e)[:200]}"

    if not listed:
        msg = f"No NDJSON batch files found under {stage_dir}"
        try:
            session.sql(f'''
                UPDATE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET download_status = 'load_failed',
                    error_message = '{msg[:200]}'
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass
        return msg
    
    try:
        copy_sql = f'''
            COPY INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM (data_date, raw_json, loaded_at)
            FROM (
                SELECT 
                    '{p_date}'::DATE,
                    $1,
                    CURRENT_TIMESTAMP()
                FROM {stage_dir}
            )
            FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP)
            PATTERN = '.*\\\\.ndjson\\\\.gz'
            ON_ERROR = CONTINUE
        '''
        session.sql(copy_sql).collect()

        rows_loaded = session.sql(
            f"SELECT COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = '{p_date}'::DATE"
        ).collect()[0][0]

        try:
            session.sql(f'''
                UPDATE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET loaded_at = CURRENT_TIMESTAMP(),
                    rows_loaded = {rows_loaded},
                    download_status = IFF(download_status = 'extracted', 'loaded', download_status)
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass

        return f"Loaded {rows_loaded} aircraft to interim table from NDJSON batches"
    except Exception as e:
        try:
            session.sql(f'''
                UPDATE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET download_status = 'load_failed',
                    error_message = '{str(e)[:200]}'
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass
        return f"Error loading JSON files: {str(e)[:200]}"
$$;

-- =============================================================================
-- Procedure: Filter and insert using SQL ST_DWITHIN (parallel processing)
-- This is where the magic happens - Snowflake parallelizes the filtering
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_FILTER_AND_INSERT_SQL(p_date VARCHAR)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_aircraft_count INT;
    v_points_inserted INT;
BEGIN
    -- Count aircraft in interim
    SELECT COUNT(*) INTO v_aircraft_count FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = :p_date::DATE;

    -- Restart-safe processing: remove any previously inserted points for this day (user-approved).
    DELETE FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW
    WHERE timestamp::DATE = :p_date::DATE;
    
    -- Insert filtered points using ST_DWITHIN (50km = 50000 meters)
    -- This runs in parallel across all Snowflake workers
    INSERT INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW (
        hex, flight, registration, aircraft_type, aircraft_desc,
        lat, lon, alt_baro, alt_geom,
        ground_speed, track, true_heading, vertical_rate,
        squawk, category, timestamp, ingested_at
    )
    WITH airport AS (
        SELECT geometry FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT LIMIT 1
    )
    SELECT 
        UPPER(i.raw_json:icao::VARCHAR) AS hex,
        -- Historical ADSB.lol "trace_full" files often do NOT have a top-level "flight".
        -- Instead, callsign/flight appears inside the per-point metadata object within the trace array
        -- (commonly at pt.value[8]:flight). Use that, and propagate within the aircraft stream.
        COALESCE(
            NULLIF(UPPER(TRIM(i.raw_json:flight::VARCHAR)), ''),
            NULLIF(UPPER(TRIM(pt.value[8]:flight::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:flight::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS flight,
        UPPER(TRIM(i.raw_json:r::VARCHAR)) AS registration,
        i.raw_json:t::VARCHAR AS aircraft_type,
        -- Historical schema: aircraft description is top-level "desc"
        -- Use quoted key access for robustness and normalize blanks to NULL.
        NULLIF(TRIM(COALESCE(
            i.raw_json:"desc"::VARCHAR,
            i.raw_json:desc::VARCHAR
        )), '') AS aircraft_desc,
        pt.value[1]::FLOAT AS lat,
        pt.value[2]::FLOAT AS lon,
        CASE 
            WHEN pt.value[3]::VARCHAR = 'ground' OR pt.value[3] IS NULL THEN 0
            ELSE TRY_CAST(pt.value[3]::VARCHAR AS INT)
        END AS alt_baro,
        TRY_CAST(pt.value[8]:alt_geom::VARCHAR AS INT) AS alt_geom,
        pt.value[4]::FLOAT AS ground_speed,
        COALESCE(
            TRY_CAST(pt.value[8]:track::VARCHAR AS FLOAT),
            pt.value[5]::FLOAT
        ) AS track,
        COALESCE(
            TRY_CAST(pt.value[8]:true_heading::VARCHAR AS FLOAT),
            pt.value[8]:true_heading::FLOAT
        ) AS true_heading,
        COALESCE(
            TRY_CAST(pt.value[8]:baro_rate::VARCHAR AS INT),
            TRY_CAST(pt.value[8]:geom_rate::VARCHAR AS INT),
            TRY_CAST(pt.value[7]::VARCHAR AS INT)
        ) AS vertical_rate,
        COALESCE(
            NULLIF(UPPER(TRIM(pt.value[8]:squawk::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:squawk::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS squawk,
        COALESCE(
            NULLIF(UPPER(TRIM(pt.value[8]:category::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:category::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS category,
        -- pt.value[0] is seconds (often fractional) since raw_json:timestamp epoch
        TIMESTAMPADD(
            'millisecond',
            -- pt.value[0] is VARIANT->FLOAT; ROUND() returns numeric already.
            -- Using TRY_CAST here can fail compilation depending on inferred numeric types, so use a plain CAST.
            CAST(ROUND(COALESCE(pt.value[0]::FLOAT, 0) * 1000) AS INT),
            TO_TIMESTAMP(i.raw_json:timestamp::NUMBER)
        ) AS timestamp,
        CURRENT_TIMESTAMP() AS ingested_at
    FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM i,
         LATERAL FLATTEN(input => i.raw_json:trace) pt,
         airport a
    WHERE i.data_date = :p_date::DATE
      AND i.raw_json:trace IS NOT NULL
      AND ARRAY_SIZE(i.raw_json:trace) > 0
      AND pt.value[1] IS NOT NULL
      AND pt.value[2] IS NOT NULL
      AND ST_DWITHIN(
          ST_MAKEPOINT(pt.value[2]::FLOAT, pt.value[1]::FLOAT),
          a.geometry,
          50000
      );

    -- Exact inserted row count for this run
    v_points_inserted := SQLROWCOUNT;
    
    -- Update status
    UPDATE ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS 
    SET download_status = 'processed', 
        processed_at = CURRENT_TIMESTAMP(),
        aircraft_found = :v_aircraft_count,
        points_inserted = :v_points_inserted
    WHERE data_date = :p_date::DATE;
    
    -- Clean up interim table for this date
    DELETE FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = :p_date::DATE;
    
    -- Run ETL to silver
    CALL ${DATABASE}.${SCHEMA}.PROC_ETL_ADSB_TO_DATA();
    
    RETURN 'Filtered ' || v_aircraft_count || ' aircraft, inserted ' || v_points_inserted || ' points within 50km';
END;
$$;

-- =============================================================================
-- Procedure: Combined process (Extract + Load + Filter)
-- Entry point that orchestrates the 3-step process
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_PROCESS_FROM_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'process_day'
AS
$$
def process_day(session, p_date):
    # Snowflake Scripting does NOT allow "CALL ... INTO var" inside SQL procedures.
    # This Python orchestrator keeps the same behavior but safely captures return values.

    # Skip if already processed and raw has data for this date
    try:
        # IMPORTANT: avoid triple-quoted strings here because this procedure body itself is embedded
        # inside the installer's triple-quoted SQL templates.
        already_sql = (
            "SELECT IFF( "
            "  EXISTS ( "
            "    SELECT 1 FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "    WHERE data_date = '" + p_date + "'::DATE AND LOWER(download_status) = 'processed' "
            "  ) "
            "  AND EXISTS ( "
            "    SELECT 1 FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW "
            "    WHERE timestamp::DATE = '" + p_date + "'::DATE LIMIT 1 "
            "  ), "
            "  1, 0 "
            ")"
        )
        already = session.sql(already_sql).collect()
        if already and int(already[0][0]) == 1:
            return "Already processed " + str(p_date)
    except Exception:
        # If this check fails for any reason, continue with processing (still restart-safe).
        pass

    def call1(sql):
        res = session.sql(sql).collect()
        return (res[0][0] if res else None) or ""

    # Step 0: Ensure TAR parts exist (download is resume-safe)
    download_msg = call1("CALL ${DATABASE}.${SCHEMA}.PROC_DOWNLOAD_TO_STAGE('" + p_date + "')")
    low0 = (download_msg or "").lower()
    if ("download failed:" in low0) or ("no tar parts" in low0) or ("partial download:" in low0):
        return download_msg

    # Step 1: Extract TAR to stage (streaming)
    extract_msg = call1("CALL ${DATABASE}.${SCHEMA}.PROC_EXTRACT_TO_NDJSON('" + p_date + "')")
    low = extract_msg.lower()
    if low.startswith("error") or low.startswith("tar error:") or ("no aircraft traces" in low):
        return download_msg + " | " + extract_msg

    # Step 2: Load extracted NDJSON batches
    load_msg = call1("CALL ${DATABASE}.${SCHEMA}.PROC_LOAD_NDJSON_TO_INTERIM('" + p_date + "')")
    low = load_msg.lower()
    if low.startswith("error") or ("error loading" in low):
        return download_msg + " | " + extract_msg + " | " + load_msg

    # Step 3: Filter with SQL and insert
    filter_msg = call1("CALL ${DATABASE}.${SCHEMA}.PROC_FILTER_AND_INSERT_SQL('" + p_date + "')")
    return download_msg + " | " + extract_msg + " | " + load_msg + " | " + filter_msg
$$;

-- =============================================================================
-- Procedure: Backfill last ${ADSB_HISTORY_BACKFILL_DAYS} UTC days (download + process), ending yesterday
-- Configurable via installer UI.
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_BACKFILL_ADSB_HISTORY()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'backfill_week'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def backfill_week(session):
    '''Backfill last N UTC days ending yesterday (N injected at install time).'''
    results = []
    
    end_date = datetime.utcnow().date() - timedelta(days=1)  # Yesterday
    n_days = ${ADSB_HISTORY_BACKFILL_DAYS}
    if n_days is None or int(n_days) < 1:
        return "Backfill skipped (adsb_history_backfill_days < 1)"
    start_date = end_date - timedelta(days=int(n_days) - 1)
    
    # Phase 1: Download all days
    results.append("=== DOWNLOADING ===")
    current = start_date
    while current <= end_date:
        date_str = current.strftime('%Y-%m-%d')
        try:
            result = session.sql(f"CALL ${DATABASE}.${SCHEMA}.PROC_DOWNLOAD_TO_STAGE('{date_str}')").collect()
            msg = result[0][0] if result else "No result"
            results.append(f"{date_str}: {msg}")
        except Exception as e:
            results.append(f"{date_str}: Download error - {str(e)[:100]}")
        current += timedelta(days=1)
    
    # Phase 2: Process all days
    results.append("=== PROCESSING ===")
    current = start_date
    while current <= end_date:
        date_str = current.strftime('%Y-%m-%d')
        try:
            result = session.sql(f"CALL ${DATABASE}.${SCHEMA}.PROC_PROCESS_FROM_STAGE('{date_str}')").collect()
            msg = result[0][0] if result else "No result"
            results.append(f"{date_str}: {msg}")
        except Exception as e:
            results.append(f"{date_str}: Process error - {str(e)[:100]}")
        current += timedelta(days=1)

    # Cleanup ONLY when all days are processed successfully
    try:
        start_str = start_date.strftime('%Y-%m-%d')
        end_str = end_date.strftime('%Y-%m-%d')
        processed_cnt = session.sql(
            f"SELECT COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            f"WHERE data_date BETWEEN '{start_str}'::DATE AND '{end_str}'::DATE "
            f"AND LOWER(download_status) = 'processed'"
        ).collect()[0][0]
    except Exception:
        processed_cnt = 0

    if processed_cnt == int(n_days):
        # Avoid nested f-string braces here (this Python proc is generated by a Python f-string)
        results.append("=== CLEANUP (all %d days processed) ===" % int(n_days))
        current = start_date
        while current <= end_date:
            date_str = current.strftime('%Y-%m-%d')
            try:
                session.sql(f"CALL ${DATABASE}.${SCHEMA}.PROC_CLEANUP_STAGE('{date_str}')").collect()
                results.append(f"{date_str}: cleaned stage")
            except Exception as e:
                results.append(f"{date_str}: cleanup error - {str(e)[:100]}")
            current += timedelta(days=1)
    else:
        results.append(f"=== CLEANUP SKIPPED (processed {processed_cnt}/${ADSB_HISTORY_BACKFILL_DAYS} days) ===")
    
    return "\\n".join(results)
$$;

-- =============================================================================
-- Procedure: Kick off historical backfill as a one-time background task
-- Runs server-side, so Streamlit can be closed; task self-suspends when done.
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_START_BACKFILL_HISTORY()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Create/replace a one-time task that runs soon (every minute) and self-suspends after the first run.
  -- NOTE: Some Snowflake accounts/regions don't support SYSTEM$TASK_FORCE_RUN; we avoid it for portability.
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_ADSB_BACKFILL_ONCE
      WAREHOUSE = ${WAREHOUSE}
      SCHEDULE = ''1 MINUTE''
      -- 5-day backfill can take a while (downloads + extract + SQL filter). Give it room.
      USER_TASK_TIMEOUT_MS = 86400000
      ALLOW_OVERLAPPING_EXECUTION = FALSE
    AS
      CALL ${DATABASE}.${SCHEMA}.PROC_RUN_BACKFILL_ONCE();
  ';

  EXECUTE IMMEDIATE 'ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ADSB_BACKFILL_ONCE RESUME';
  RETURN 'Started TASK_ADSB_BACKFILL_ONCE. It will run within ~1 minute and then self-suspend. Monitor ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS.';
END;
$$;

-- Wrapper procedure invoked by the task; self-suspends the task after completion
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_RUN_BACKFILL_ONCE()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_once'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def _get_config_backfill_days(session, default_days):
    # Read configured adsb_history_backfill_days from HELPER_MONITOR_LAST_REFRESH.
    try:
        rows = session.sql(
            "SELECT COALESCE(row_count_24h, %d) AS val FROM ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH "
            "WHERE table_name = 'CONFIG_ADSB_BACKFILL_DAYS'" % (int(default_days),)
        ).collect()
        return int(rows[0][0]) if rows else int(default_days)
    except Exception:
        return int(default_days)

def _is_backfill_complete(session, backfill_days):
    if backfill_days < 1:
        return True, 0, 0
    today = datetime.utcnow().date()
    start_date = today - timedelta(days=int(backfill_days))
    end_date = today - timedelta(days=1)
    try:
        rows = session.sql(
            "SELECT COUNT(*) AS cnt FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date BETWEEN '%s'::DATE AND '%s'::DATE "
            "AND LOWER(download_status) = 'processed'"
            % (start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'))
        ).collect()
        processed = int(rows[0][0]) if rows else 0
        return processed >= int(backfill_days), processed, int(backfill_days)
    except Exception:
        return False, 0, int(backfill_days)

def _wait_for_backfill_complete(session, backfill_days):
    for attempt in range(MAX_GATE_ATTEMPTS):
        complete, processed, expected = _is_backfill_complete(session, backfill_days)
        if complete:
            return True, processed, expected
        if attempt < MAX_GATE_ATTEMPTS - 1:
            time.sleep(GATE_SLEEP_SECONDS)
    return False, processed, expected

def run_once(session):
    msg = ""
    try:
        res = session.sql("CALL ${DATABASE}.${SCHEMA}.PROC_BACKFILL_ADSB_HISTORY()").collect()
        msg = (res[0][0] if res else None) or ""

        # After backfill completes, wait for expected days to be fully processed before enrich/refresh.
        config_days = _get_config_backfill_days(session, ${ADSB_HISTORY_BACKFILL_DAYS})
        complete, processed, expected = _wait_for_backfill_complete(session, config_days)
        if not complete:
            msg += " | Backfill not complete (processed %d/%d days); continuing with enrichment" % (processed, expected)

        # Enrichment should still run even if today's history isn't available yet.
        try:
            enrich_res = session.sql(
                "CALL ${DATABASE}.${SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(%d)" % (int(config_days),)
            ).collect()
            enrich_msg = (enrich_res[0][0] if enrich_res else None) or ""
            msg += " | " + enrich_msg
        except Exception as e:
            msg += " | Enrichment failed: " + str(e)[:200]

        # Always attempt a derived refresh after the backfill task completes.
        try:
            refresh_res = session.sql("CALL ${DATABASE}.${SCHEMA}.PROC_REFRESH_DERIVED()").collect()
            refresh_msg = (refresh_res[0][0] if refresh_res else None) or ""
            if refresh_msg:
                msg += " | " + refresh_msg
        except Exception as e:
            msg += " | Derived refresh failed: " + str(e)[:200]
        
        # Trigger manual refresh of all Dynamic Tables (event-driven)
        try:
            session.sql("EXECUTE TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_ANALYTICS").collect()
            msg += " | Analytics refreshed"
        except Exception as e:
            msg += " | Analytics refresh failed: " + str(e)[:200]
    except Exception as e:
        msg = "Backfill failed: " + str(e)[:200]
    # Always try to self-suspend the one-time task, even on errors.
    try:
        session.sql("ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ADSB_BACKFILL_ONCE SUSPEND").collect()
    except Exception:
        pass
    return msg
$$;

-- =============================================================================
-- Continuous retry backfill (UTC): keep trying yesterday + today until available,
-- and trigger enrichment + derived refresh only after the full configured window is processed.
-- This closes the "start-day gap" (midnight -> ingestion start time) as soon as
-- the daily history release for "today" becomes available (often the next day).
-- =============================================================================

CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_RUN_BACKFILL_RETRY_UTC()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_retry'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def _get_status(session, date_str):
    try:
        rows = session.sql(
            "SELECT LOWER(download_status) AS st FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date = '%s'::DATE" % (date_str,)
        ).collect()
        return (rows[0][0] if rows else None) or None
    except Exception:
        return None

def _ensure_row(session, date_str):
    try:
        session.sql(
            "MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t "
            "USING (SELECT '%s'::DATE AS data_date) s ON t.data_date = s.data_date "
            "WHEN NOT MATCHED THEN INSERT (data_date, download_status) VALUES (s.data_date, 'pending')"
            % (date_str,)
        ).collect()
    except Exception:
        pass

def _get_config_backfill_days(session):
    # Read configured adsb_history_backfill_days from HELPER_MONITOR_LAST_REFRESH.
    try:
        rows = session.sql(
            "SELECT COALESCE(row_count_24h, 7) AS val FROM ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH "
            "WHERE table_name = 'CONFIG_ADSB_BACKFILL_DAYS'"
        ).collect()
        return int(rows[0][0]) if rows else 7
    except Exception:
        return 7

def _is_backfill_complete(session, backfill_days):
    if backfill_days < 1:
        return True, 0, 0
    today = datetime.utcnow().date()
    start_date = today - timedelta(days=int(backfill_days))
    end_date = today - timedelta(days=1)
    try:
        rows = session.sql(
            "SELECT COUNT(*) AS cnt FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date BETWEEN '%s'::DATE AND '%s'::DATE "
            "AND LOWER(download_status) = 'processed'"
            % (start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'))
        ).collect()
        processed = int(rows[0][0]) if rows else 0
        return processed >= int(backfill_days), processed, int(backfill_days)
    except Exception:
        return False, 0, int(backfill_days)

def _wait_for_backfill_complete(session, backfill_days):
    for attempt in range(MAX_GATE_ATTEMPTS):
        complete, processed, expected = _is_backfill_complete(session, backfill_days)
        if complete:
            return True, processed, expected
        if attempt < MAX_GATE_ATTEMPTS - 1:
            time.sleep(GATE_SLEEP_SECONDS)
    return False, processed, expected

def run_retry(session):
    today = datetime.utcnow().date()
    dates = [today - timedelta(days=1), today]  # yesterday (expected) + today (best-effort)
    results = []

    # Read configured backfill window to use for enrichment lookback
    config_backfill_days = _get_config_backfill_days(session)
    max_enrich_days = config_backfill_days + 1  # +1 to cover edge cases

    for d in dates:
        date_str = d.strftime('%Y-%m-%d')
        _ensure_row(session, date_str)

        before = _get_status(session, date_str)
        if before == 'processed':
            results.append("%s: already processed" % (date_str,))
            continue

        # Process (download/extract/load/filter); this is resume-safe per date.
        try:
            r = session.sql("CALL ${DATABASE}.${SCHEMA}.PROC_PROCESS_FROM_STAGE('%s')" % (date_str,)).collect()
            msg = (r[0][0] if r else None) or ""
        except Exception as e:
            msg = "process failed: " + str(e)[:200]

        after = _get_status(session, date_str)
        results.append("%s: %s (status=%s)" % (date_str, msg, after))

        # Defer enrichment/refresh until the full configured backfill window is processed.

    complete, processed, expected = _wait_for_backfill_complete(session, config_backfill_days)
    if complete:
        try:
            session.sql(
                "CALL ${DATABASE}.${SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(%d)" % (int(max_enrich_days),)
            ).collect()
            session.sql("CALL ${DATABASE}.${SCHEMA}.PROC_REFRESH_DERIVED()").collect()
            session.sql("EXECUTE TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_ANALYTICS").collect()
            results.append("triggered enrich+refresh+analytics after backfill complete (processed=%d/%d)" % (processed, expected))
        except Exception as e:
            results.append("enrich/refresh/analytics failed after backfill complete: %s" % (str(e)[:200],))
    else:
        results.append("backfill not complete (processed %d/%d days); enrich/refresh skipped" % (processed, expected))

    return "\\n".join(results)
$$;

-- Task wrapper: keep TASK body as a single CALL (installer statement-splitting safe)
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_START_BACKFILL_RETRY_UTC()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_ADSB_BACKFILL_RETRY
      WAREHOUSE = ${WAREHOUSE}
      SCHEDULE = ''60 MINUTE''
      USER_TASK_TIMEOUT_MS = 21600000
      ALLOW_OVERLAPPING_EXECUTION = FALSE
    AS
      CALL ${DATABASE}.${SCHEMA}.PROC_RUN_BACKFILL_RETRY_UTC();
  ';

  EXECUTE IMMEDIATE 'ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ADSB_BACKFILL_RETRY RESUME';
  RETURN 'Started TASK_ADSB_BACKFILL_RETRY (yesterday+today UTC retry + enrich). Monitor HELPER_ADSB_BACKFILL_STATUS.';
END;
$$;

-- =============================================================================
-- Procedure: Cleanup stage after processing
-- =============================================================================
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_CLEANUP_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    REMOVE @${DATABASE}.${SCHEMA}.ADSB_HISTORY_STAGE/:p_date/;
    RETURN 'Cleaned up ' || :p_date;
END;
$$;

-- =============================================================================
-- USAGE:
-- Download one day to stage:
--   CALL ${DATABASE}.${SCHEMA}.PROC_DOWNLOAD_TO_STAGE('2025-12-15');
--
-- Process from stage:
--   CALL ${DATABASE}.${SCHEMA}.PROC_PROCESS_FROM_STAGE('2025-12-15');
--
-- Backfill full week (download + process):
--   CALL ${DATABASE}.${SCHEMA}.PROC_BACKFILL_ADSB_HISTORY();
--
-- Check status:
--   SELECT * FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS;
--
-- Cleanup stage:
--   CALL ${DATABASE}.${SCHEMA}.PROC_CLEANUP_STAGE('2025-12-15');
-- =============================================================================
"""
