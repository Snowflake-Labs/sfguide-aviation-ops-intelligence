-- =============================================================================
-- TSA Throughput Pipeline — Full Setup Script
-- =============================================================================
-- Description : Fetches the weekly TSA checkpoint throughput PDF from the
--               TSA FOIA reading room, splits it into 1-page PDFs, extracts
--               structured tabular data via AI_EXTRACT, and loads it into a
--               Snowflake table. Runs automatically every Monday at 9am PT.
--
-- Prerequisites:
--   1. A role with OWNERSHIP (or CREATE privilege) on the target schema
--   2. An External Access Integration (EAI) allowing outbound HTTPS
--      Default: BROAD_EAI_INTEGRATION — update PARAM_EAI below if different
--   3. USAGE on the target warehouse
--
-- Customise the four PARAM_ variables below before running.
-- =============================================================================

-- ── Parameters (edit these before running) ────────────────────────────────────
SET PARAM_DB        = 'TEMP';
SET PARAM_SCHEMA    = 'NEJAIN';
SET PARAM_WAREHOUSE = 'SNOWHOUSE';
SET PARAM_EAI       = 'BROAD_EAI_INTEGRATION';

-- ── Context ───────────────────────────────────────────────────────────────────
USE DATABASE   IDENTIFIER($PARAM_DB);
USE SCHEMA     IDENTIFIER($PARAM_SCHEMA);
USE WAREHOUSE  IDENTIFIER($PARAM_WAREHOUSE);

-- ── Attribution tracking (required for every session that creates objects) ────
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

-- =============================================================================
-- 1. STAGES
-- Both stages must use SNOWFLAKE_SSE encryption — required for AI_EXTRACT.
-- =============================================================================

CREATE STAGE IF NOT EXISTS TSA_pdf_stage
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE STAGE IF NOT EXISTS TSA_pdf_pages_stage
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

-- =============================================================================
-- 2. TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS tsa_throughput (
    source_file        VARCHAR,
    page_file          VARCHAR,
    date               VARCHAR,
    hour_of_day        VARCHAR,
    airport_code       VARCHAR,
    airport_name       VARCHAR,
    city               VARCHAR,
    state              VARCHAR,
    checkpoint         VARCHAR,
    total_pax_kcm_pax  VARCHAR,
    extracted_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

-- =============================================================================
-- 3. STORED PROCEDURES  (in dependency order)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3a. fetch_pdf_to_stage(url, stage_path)
--     Generic utility: downloads any PDF URL and uploads it to a stage
--     with a timestamp prefix. No other SP dependencies.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE fetch_pdf_to_stage(url STRING, stage_path STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (BROAD_EAI_INTEGRATION)   -- update if using a different EAI
HANDLER = 'run'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS $$
import io
import requests
from datetime import datetime

def run(session, url: str, stage_path: str) -> str:
    session.sql(f"ALTER SESSION SET WAREHOUSE = {session.get_current_warehouse() or 'SNOWHOUSE'}").collect()

    response = requests.get(url, timeout=30)
    response.raise_for_status()

    pdf_bytes = io.BytesIO(response.content)
    filename  = url.split('?')[0].split('/')[-1]
    if not filename.lower().endswith('.pdf'):
        filename += '.pdf'

    timestamp       = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    staged_filename = f'{timestamp}_{filename}'

    session.file.put_stream(pdf_bytes, f'{stage_path}/{staged_filename}', auto_compress=False)
    return f'Success: uploaded {staged_filename} to {stage_path}'
$$;


-- -----------------------------------------------------------------------------
-- 3b. fetch_latest_tsa_throughput_pdf(stage_path)
--     Scrapes the TSA FOIA reading room, finds the latest throughput PDF,
--     deduplicates against already-staged files, then delegates the
--     actual download to fetch_pdf_to_stage.
--     Depends on: fetch_pdf_to_stage
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE fetch_latest_tsa_throughput_pdf(stage_path STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (BROAD_EAI_INTEGRATION)   -- update if using a different EAI
HANDLER = 'run'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS $$
import re
import requests
from datetime import datetime

FOIA_PAGE = 'https://www.tsa.gov/foia/readingroom/'
BASE_URL  = 'https://www.tsa.gov'
PATTERN   = re.compile(r'href="(/sites/default/files/foia-readingroom/tsa-throughput-data-[^"]+\.pdf)"')

MONTH_MAP = {
    'january':1,'february':2,'march':3,'april':4,'may':5,'june':6,
    'july':7,'august':8,'september':9,'october':10,'november':11,'december':12
}

def parse_end_date(filename):
    m = re.search(r'-to-(\w+)-(\d+)-(\d{4})\.pdf$', filename)
    if m:
        month, day, year = m.group(1).lower(), int(m.group(2)), int(m.group(3))
        return datetime(year, MONTH_MAP.get(month, 1), day)
    return datetime.min

def run(session, stage_path: str) -> str:
    session.sql(f"ALTER SESSION SET WAREHOUSE = {session.get_current_warehouse() or 'SNOWHOUSE'}").collect()

    html  = requests.get(FOIA_PAGE, timeout=30).text
    paths = PATTERN.findall(html)
    if not paths:
        return 'Error: no throughput PDF links found on FOIA page'

    latest_path = max(paths, key=lambda p: parse_end_date(p.split('/')[-1]))
    url         = BASE_URL + latest_path
    filename    = url.split('/')[-1]

    staged = [row['name'] for row in session.sql(f'LIST {stage_path}').collect()]
    if any(filename in s for s in staged):
        return f'Already up to date: {filename} is already in {stage_path}'

    db     = session.get_current_database()
    schema = session.get_current_schema()
    result = session.sql(
        f"CALL {db}.{schema}.fetch_pdf_to_stage('{url}', '{stage_path}')"
    ).collect()[0][0]
    return result
$$;


-- -----------------------------------------------------------------------------
-- 3c. process_tsa_pdf(pages_stage, target_table)
--     Auto-discovers the latest PDF in TSA_pdf_stage, splits it into
--     1-page files, runs AI_EXTRACT on each page, flattens the results,
--     bulk-inserts into the target table, and cleans up the pages stage.
--     Depends on: TSA_pdf_stage (stage), TSA_pdf_pages_stage (stage),
--                 tsa_throughput (table)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE process_tsa_pdf(pages_stage VARCHAR, target_table VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdf')
HANDLER = 'run'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS $$
import io
import json
import os
import tempfile
import pypdf

def run(session, pages_stage: str, target_table: str) -> str:
    db           = session.get_current_database()
    schema       = session.get_current_schema()
    source_stage = f'@{db}.{schema}.TSA_pdf_stage'

    session.sql(f"ALTER SESSION SET WAREHOUSE = {session.get_current_warehouse() or 'SNOWHOUSE'}").collect()

    # ── 1. Discover latest PDF in source stage ────────────────────────────
    files     = session.sql(f'LIST {source_stage}').collect()
    pdf_files = sorted(
        [r['name'].split('/')[-1] for r in files if r['name'].endswith('.pdf')],
        reverse=True
    )
    if not pdf_files:
        return 'No PDF found in source stage — run fetch_latest_tsa_throughput_pdf first'
    source_file = pdf_files[0]

    # ── 2. Download PDF from source stage to /tmp ─────────────────────────
    with tempfile.TemporaryDirectory() as tmpdir:
        session.file.get(f'{source_stage}/{source_file}', tmpdir)
        local_path = os.path.join(tmpdir, os.path.basename(source_file))
        with open(local_path, 'rb') as f:
            pdf_bytes = f.read()

    reader    = pypdf.PdfReader(io.BytesIO(pdf_bytes))
    num_pages = len(reader.pages)

    # ── 3. Split into 1-page files and upload to pages_stage ──────────────
    for i, page in enumerate(reader.pages):
        writer = pypdf.PdfWriter()
        writer.add_page(page)
        buf = io.BytesIO()
        writer.write(buf)
        buf.seek(0)
        session.file.put_stream(buf, f'{pages_stage}/page_{i+1:04d}.pdf', auto_compress=False)

    # ── 4. Refresh directory table ────────────────────────────────────────
    stage_name = pages_stage.lstrip('@')
    session.sql(f'ALTER STAGE {stage_name} REFRESH').collect()

    # ── 5. AI_EXTRACT on all 1-pagers ─────────────────────────────────────
    schema_json = {
        "schema": {
            "type": "object",
            "properties": {
                "rows": {
                    "type": "object",
                    "description": "All data rows from the table in this document",
                    "column_ordering": [
                        "date","hour_of_day","airport_code","airport_name",
                        "city","state","checkpoint","total_pax_kcm_pax"
                    ],
                    "properties": {
                        "date":              {"type": "array", "description": "Date column"},
                        "hour_of_day":       {"type": "array", "description": "Hour of Day column"},
                        "airport_code":      {"type": "array", "description": "Airport Code column"},
                        "airport_name":      {"type": "array", "description": "Airport Name column"},
                        "city":              {"type": "array", "description": "City column"},
                        "state":             {"type": "array", "description": "State column"},
                        "checkpoint":        {"type": "array", "description": "Checkpoint column"},
                        "total_pax_kcm_pax": {"type": "array", "description": "Total Pax + KCM PAX column"}
                    }
                }
            }
        }
    }
    schema_str = json.dumps(schema_json)

    extract_sql = f"""
        SELECT
            SPLIT_PART(relative_path, '/', -1) AS page_file,
            AI_EXTRACT(
                file          => TO_FILE('{pages_stage}', SPLIT_PART(relative_path, '/', -1)),
                responseFormat => PARSE_JSON('{schema_str}')
            ):response AS result
        FROM DIRECTORY({pages_stage})
        WHERE relative_path ILIKE '%.pdf'
        ORDER BY relative_path
    """
    extract_rows = session.sql(extract_sql).collect()

    # ── 6. Flatten parallel arrays and build insert rows ──────────────────
    insert_rows = []
    for r in extract_rows:
        page_file = r['PAGE_FILE']
        raw       = r['RESULT']
        if not raw:
            continue
        data = json.loads(raw) if isinstance(raw, str) else raw
        tbl  = data.get('rows', {}) if data else {}

        dates  = tbl.get('date', [])              or []
        hours  = tbl.get('hour_of_day', [])        or []
        codes  = tbl.get('airport_code', [])       or []
        names  = tbl.get('airport_name', [])       or []
        cities = tbl.get('city', [])               or []
        states = tbl.get('state', [])              or []
        chkpts = tbl.get('checkpoint', [])         or []
        pax    = tbl.get('total_pax_kcm_pax', [])  or []

        for i in range(len(dates)):
            def s(lst, idx=i): return str(lst[idx]).replace("'","''") if idx < len(lst) and lst[idx] is not None else ''
            insert_rows.append(
                f"('{source_file}','{page_file}','{s(dates)}','{s(hours)}',"
                f"'{s(codes)}','{s(names)}','{s(cities)}','{s(states)}',"
                f"'{s(chkpts)}','{s(pax)}',CURRENT_TIMESTAMP())"
            )

    # ── 7. Bulk insert in batches of 500 ──────────────────────────────────
    total_inserted = 0
    if insert_rows:
        for b in range(0, len(insert_rows), 500):
            batch = insert_rows[b:b+500]
            session.sql(f"""
                INSERT INTO {target_table}
                    (source_file,page_file,date,hour_of_day,airport_code,
                     airport_name,city,state,checkpoint,total_pax_kcm_pax,extracted_at)
                VALUES {','.join(batch)}
            """).collect()
            total_inserted += len(batch)

    # ── 8. Cleanup: remove all files from pages stage ─────────────────────
    session.sql(f"REMOVE {pages_stage} PATTERN='.*'").collect()

    return (f'Source: {source_file} | '
            f'Split: {num_pages} pages | '
            f'Inserted: {total_inserted} rows into {target_table} | '
            f'Pages stage cleared')
$$;


-- =============================================================================
-- 4. TASKS  (child must be created before root is resumed)
--    Root task  : fetch_tsa_pdf_task   — runs on schedule, fetches PDF
--    Child task : extract_tsa_pdf_task — runs after fetch, extracts data
-- =============================================================================

-- Root task (suspend first in case it already exists)
CREATE OR REPLACE TASK fetch_tsa_pdf_task
  WAREHOUSE = SNOWHOUSE                                      -- update to match PARAM_WAREHOUSE
  SCHEDULE  = 'USING CRON 0 9 * * 1 America/Los_Angeles'   -- every Monday 9am PT
  COMMENT   = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
  CALL fetch_latest_tsa_throughput_pdf('@TSA_pdf_stage');   -- note: unqualified, resolved via USE SCHEMA above

-- Child task (chained after root)
CREATE OR REPLACE TASK extract_tsa_pdf_task
  WAREHOUSE = SNOWHOUSE                                      -- update to match PARAM_WAREHOUSE
  COMMENT   = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AFTER     fetch_tsa_pdf_task
AS
  CALL process_tsa_pdf(
    '@TSA_pdf_pages_stage',
    'tsa_throughput'
  );

-- =============================================================================
-- 5. RESUME TASKS  (child first, then root — Snowflake requirement)
-- =============================================================================
ALTER TASK extract_tsa_pdf_task RESUME;
ALTER TASK fetch_tsa_pdf_task   RESUME;

-- =============================================================================
-- Verification
-- =============================================================================
SHOW STAGES   IN SCHEMA IDENTIFIER($PARAM_SCHEMA);
SHOW TABLES   IN SCHEMA IDENTIFIER($PARAM_SCHEMA);
SHOW PROCEDURES IN SCHEMA IDENTIFIER($PARAM_SCHEMA);
SHOW TASKS    IN SCHEMA IDENTIFIER($PARAM_SCHEMA);
