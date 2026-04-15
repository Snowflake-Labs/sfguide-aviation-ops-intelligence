# Historical Backfill Infrastructure

> **Placeholders** (replaced by the skill at generation time):
> - `{TARGET_DB}` — Snowflake database, e.g. `AIRPORT_SAN`
> - `{SCHEMA}` — Schema, e.g. `PUBLIC`
> - `{WAREHOUSE}` — Warehouse name
> - `{EAI_ADSB_LOL}` — External Access Integration name for adsb.lol (e.g. `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`)
> - `{EAI_GITHUB}` — External Access Integration name for GitHub (e.g. `AIRPORT_SAN_PUBLIC_GITHUB_EAI`)
> - `{API_URL}` — adsb.lol API endpoint with lat/lon/radius (e.g. `https://api.adsb.lol/v2/point/32.7336/-117.1897/27`)
> - `{BACKFILL_DAYS}` — Number of historical days to backfill (e.g. `7`)
> - `{IATA}` — Airport IATA code (e.g. `SAN`)

The **COMMENT tag** used on every `CREATE` statement:
```
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
```


---

### PROC_DOWNLOAD_TO_STAGE

```sql
-- =============================================================================
-- Procedure: Download TAR files to internal stage
-- Downloads split TAR parts from globe_history_YYYY to stage for later processing
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_DOWNLOAD_TO_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'download_to_stage'
EXTERNAL_ACCESS_INTEGRATIONS = ({EAI_GITHUB})
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
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
    stage_path = f"@{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/{p_date}"
    
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
            existing = session.sql(f"LIST {stage_path} PATTERN='.*{tag}\\.tar\\..*'").collect()
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
                    MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
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
                MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
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
            MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
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
```

### PROC_EXTRACT_TO_NDJSON

```sql
-- =============================================================================
-- Procedure: Extract TAR to batched NDJSON on stage (STREAMING)
-- PERFORMANCE: reduces stage writes from ~50k/day to ~tens/day
-- NOTE: We still avoid JSON parsing; we only gzip-decompress each trace file to get JSON bytes
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_EXTRACT_TO_NDJSON(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'extract_to_stage'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
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
    stage_path = f"@{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/{p_date}"
    
    try:
        files_result = session.sql(f"LIST {stage_path}").collect()
        if not files_result:
            return f"No files found in stage for {p_date}"
    except Exception as e:
        return f"Error listing stage: {str(e)[:100]}"
    
    # Only process .tar files, skip extracted traces
    tar_files = sorted([f"@{TARGET_DB}.{SCHEMA}.{row[0]}" for row in files_result 
                       if '.tar.' in row[0] and '/traces/' not in row[0]])
    
    if not tar_files:
        return f"No TAR files found for {p_date}"

    ndjson_dir = f"@{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/"
    # Smart resume:
    # - If NDJSON batches already exist AND status indicates extracted/loaded/processed, skip extraction.
    # - If batches exist but status does not, treat as partial and restart extraction for this day.
    try:
        existing_batches = session.sql(f"LIST {ndjson_dir} PATTERN='.*\\.ndjson\\.gz'").collect()
    except Exception:
        existing_batches = []

    if existing_batches:
        try:
            st = session.sql(f'''
                SELECT download_status, extracted_at
                FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
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
        dest = f"@{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/batch_{batch_idx:04d}.ndjson.gz"
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
                MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t
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
            UPDATE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS 
            SET download_status = 'extracted', 
                extracted_at = CURRENT_TIMESTAMP(),
                aircraft_extracted = {aircraft_written}
            WHERE data_date = '{p_date}'
        ''').collect()
    except:
        pass
    
    return f"Extracted {aircraft_written} aircraft traces to NDJSON batches (streaming, skipped {skipped} aux files)"
$$;
```

