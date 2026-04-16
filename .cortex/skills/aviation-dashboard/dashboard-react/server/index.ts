import express from 'express';
import cors from 'cors';
import { config } from 'dotenv';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { IS_SPCS, SF_WAREHOUSE, setWarehouse, CONN, SNOWFLAKE_HOST, QUERY_TAG } from './constants.js';

config();

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));

const IDENTIFIER_RE = /^[A-Za-z][A-Za-z0-9_]{0,254}$/;

function sanitizeIdentifier(val: string): string {
  const cleaned = val.replace(/[^A-Za-z0-9_]/g, '');
  if (!IDENTIFIER_RE.test(cleaned)) throw new Error(`Invalid identifier: ${val}`);
  return cleaned;
}

function escapeString(val: string): string {
  return val.replace(/\\/g, '\\\\').replace(/'/g, "''").replace(/[\x00-\x1f]/g, '');
}

function getSpcsToken(): string {
  return readFileSync('/snowflake/session/token', 'utf-8').trim();
}

function snowSqlLocal(sql: string, database?: string, schema?: string): any[] {
  const tmpFile = join(tmpdir(), `aviation_query_${Date.now()}.sql`);
  let fullSql = `ALTER SESSION SET query_tag = '${QUERY_TAG}';\nUSE WAREHOUSE ${SF_WAREHOUSE};\n`;
  if (database) fullSql += `USE DATABASE ${database};\n`;
  if (schema) fullSql += `USE SCHEMA ${schema};\n`;
  fullSql += `${sql};`;
  writeFileSync(tmpFile, fullSql);
  try {
    const result = execSync(`snow sql -c ${CONN} -f "${tmpFile}" --format json 2>/dev/null`, {
      maxBuffer: 50 * 1024 * 1024, timeout: 120000, encoding: 'utf-8',
    });
    const parsed = JSON.parse(result.trim());
    if (Array.isArray(parsed) && Array.isArray(parsed[0])) return parsed[parsed.length - 1];
    return parsed;
  } finally {
    try { unlinkSync(tmpFile); } catch {}
  }
}

async function snowSqlSpcs(sql: string, database?: string, schema?: string, timeoutSecs: number = 600): Promise<any[]> {
  console.log(`[SQL API] Executing: ${sql.slice(0, 200)} (WH: ${SF_WAREHOUSE}, DB: ${database || '-'}, HOST: ${SNOWFLAKE_HOST})`);
  const token = getSpcsToken();
  const body = {
    statement: sql,
    timeout: timeoutSecs,
    database: database || undefined,
    schema: schema || 'PUBLIC',
    warehouse: SF_WAREHOUSE,
    parameters: { QUERY_TAG },
  };
  const headers: Record<string, string> = {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Snowflake-Authorization-Token-Type': 'OAUTH',
  };
  const res = await fetch(`https://${SNOWFLAKE_HOST}/api/v2/statements`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const errBody = (await res.text()).slice(0, 500);
    throw new Error(`SQL API error ${res.status}: ${errBody}`);
  }
  let result: any = await res.json();
  if (result.statementStatusUrl && (!result.data || result.code === '333334')) {
    const pollUrl = `https://${SNOWFLAKE_HOST}${result.statementStatusUrl}`;
    for (let i = 0; i < 120; i++) {
      await new Promise((r) => setTimeout(r, 5000));
      const pr = await fetch(pollUrl, { headers });
      result = await pr.json();
      if (result.data || (result.code && result.code !== '333334')) break;
    }
  }
  if (result.message && !result.data) throw new Error(`SQL error: ${result.message}`);
  if (!result.data) return [];
  const cols = (result.resultSetMetaData?.rowType || []).map((c: any) => c.name);
  let allData: any[][] = [...(result.data || [])];
  const partitions = result.resultSetMetaData?.partitionInfo;
  if (partitions && partitions.length > 1) {
    const handle = result.statementHandle;
    for (let p = 1; p < partitions.length; p++) {
      const pr = await fetch(`https://${SNOWFLAKE_HOST}/api/v2/statements/${handle}?partition=${p}`, { headers });
      const partResult: any = await pr.json();
      if (partResult.data) allData = allData.concat(partResult.data);
    }
  }
  return allData.map((row: any[]) => {
    const obj: Record<string, any> = {};
    cols.forEach((c: string, i: number) => { obj[c] = row[i]; });
    return obj;
  });
}

async function runSql(sql: string, database?: string, schema?: string): Promise<any[]> {
  if (IS_SPCS) return snowSqlSpcs(sql, database, schema);
  return snowSqlLocal(sql, database, schema);
}

const READ_ONLY_PREFIXES = ['SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'CALL', 'WITH'];

app.post('/api/query', async (req, res) => {
  try {
    const { sql, database, schema } = req.body;
    if (!sql || typeof sql !== 'string') {
      return res.status(400).json({ error: 'Missing sql' });
    }
    const trimmed = sql.trim().toUpperCase();
    const allowed = READ_ONLY_PREFIXES.some(p => trimmed.startsWith(p));
    if (!allowed) {
      return res.status(403).json({ error: 'Only read-only queries are allowed' });
    }
    const rows = await runSql(sql, database, schema);
    res.json(rows);
  } catch (err: any) {
    console.error('[/api/query] Error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/airports', async (_req, res) => {
  try {
    const rows = await runSql("SHOW DATABASES LIKE 'AIRPORT_%'");
    const airports = (rows || []).map((r: any) => ({
      name: r.name || r.NAME,
    })).filter((a: any) => a.name);
    res.json(airports);
  } catch (err: any) {
    console.error('[/api/airports] Error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/status', (_req, res) => {
  res.json({ status: 'ok', version: '1.0.0' });
});

const tileCache = new Map<string, { data: Buffer; ts: number }>();
const TILE_TTL = 3600_000;
const MAX_TILES = 5000;

app.get('/api/tiles/:z/:x/:y', async (req, res) => {
  const { z, x, y } = req.params;
  const key = `${z}/${x}/${y}`;
  const cached = tileCache.get(key);
  if (cached && Date.now() - cached.ts < TILE_TTL) {
    res.set('Content-Type', 'image/png');
    res.set('Cache-Control', 'public, max-age=3600');
    return res.send(cached.data);
  }
  try {
    const url = `https://a.basemaps.cartocdn.com/light_all/${z}/${x}/${y}@2x.png`;
    const tileRes = await fetch(url);
    if (!tileRes.ok) return res.status(tileRes.status).end();
    const buf = Buffer.from(await tileRes.arrayBuffer());
    if (tileCache.size >= MAX_TILES) {
      const oldest = tileCache.keys().next().value;
      if (oldest) tileCache.delete(oldest);
    }
    tileCache.set(key, { data: buf, ts: Date.now() });
    res.set('Content-Type', 'image/png');
    res.set('Cache-Control', 'public, max-age=3600');
    res.send(buf);
  } catch {
    res.status(502).end();
  }
});

if (!IS_SPCS) {
  const PORT = process.env.PORT || 3001;
  app.listen(PORT, () => console.log(`Aviation dashboard server on :${PORT}`));
} else {
  const distPath = join(import.meta.dirname || '.', '..', 'dist');
  if (existsSync(distPath)) {
    app.use(express.static(distPath));
    app.get('*', (_req, res) => {
      res.sendFile(join(distPath, 'index.html'));
    });
  }
  const PORT = 3001;
  app.listen(PORT, () => console.log(`Aviation dashboard SPCS on :${PORT}`));
}
