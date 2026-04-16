import { useState, useMemo } from 'react';
import { ScatterplotLayer, GeoJsonLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import {
  BarChart, Bar, PieChart, Pie, Cell,
  XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend, Area, AreaChart,
} from 'recharts';

const COLORS_PALETTE = ['#29B5E8', '#0DB048', '#E5A100', '#E5484D', '#9B59B6', '#F39C12', '#1ABC9C', '#6E7681'];
const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function heatColor(value: number, max: number): string {
  if (max === 0) return 'var(--surface)';
  const t = Math.min(value / max, 1);
  if (t < 0.5) {
    const r = Math.round(26 + (41 - 26) * (t * 2));
    const g = Math.round(35 + (181 - 35) * (t * 2));
    const b = Math.round(50 + (232 - 50) * (t * 2));
    return `rgb(${r},${g},${b})`;
  }
  const r = Math.round(41 + (229 - 41) * ((t - 0.5) * 2));
  const g = Math.round(181 + (161 - 181) * ((t - 0.5) * 2));
  const b = Math.round(232 + (0 - 232) * ((t - 0.5) * 2));
  return `rgb(${r},${g},${b})`;
}

function intensityColor(t: number): [number, number, number, number] {
  const c = Math.max(0, Math.min(1, t));
  if (c < 0.5) {
    const f = c * 2;
    return [
      Math.round(79 + f * (255 - 79)),
      Math.round(195 + f * (193 - 195)),
      Math.round(247 + f * (7 - 247)),
      220,
    ];
  }
  const f = (c - 0.5) * 2;
  return [
    Math.round(255 + f * (255 - 255)),
    Math.round(193 + f * (87 - 193)),
    Math.round(7 + f * (34 - 7)),
    220,
  ];
}

export default function TSAThroughput() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);

  const iataSql = airport
    ? `SELECT UPPER(airport_code) AS IATA FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: iataRows } = useSfQuery(iataSql, airport, 'PUBLIC', []);
  const iata = (iataRows[0] as any)?.IATA || '';

  const tableCheckSql = airport
    ? `SELECT COUNT(*) AS CNT FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_CATALOG = '${airport}' AND TABLE_SCHEMA = 'PUBLIC' AND TABLE_NAME = 'TSA_THROUGHPUT'`
    : '';
  const { data: tableCheck } = useSfQuery(tableCheckSql, airport, 'PUBLIC', []);
  const hasTable = ((tableCheck[0] as any)?.CNT || 0) > 0;

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const viewCheckSql = airport
    ? `SELECT COUNT(*) AS CNT FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_CATALOG = '${airport}' AND TABLE_SCHEMA = 'PUBLIC' AND TABLE_NAME = 'V_TSA_CHECKPOINT_GEO'`
    : '';
  const { data: viewCheck } = useSfQuery(viewCheckSql, airport, 'PUBLIC', []);
  const hasGeoView = ((viewCheck[0] as any)?.CNT || 0) > 0;

  const geoSql = airport && iata && hasTable && hasGeoView
    ? `SELECT checkpoint AS CHECKPOINT, terminal_name AS TERMINAL_NAME,
              lat AS LAT, lon AS LON, terminal_geojson AS GEOJSON,
              match_type AS MATCH_TYPE,
              SUM(passengers) AS TOTAL_PAX,
              COUNT(DISTINCT throughput_date) AS NUM_DAYS,
              ROUND(SUM(passengers) / NULLIF(COUNT(DISTINCT throughput_date), 0)) AS DAILY_AVG
       FROM ${db}.V_TSA_CHECKPOINT_GEO
       WHERE throughput_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY 1, 2, 3, 4, 5, 6
       ORDER BY TOTAL_PAX DESC NULLS LAST`
    : '';
  const { data: geoData } = useSfQuery(geoSql, airport, 'PUBLIC', [iata, hasTable, hasGeoView, dateFrom, dateTo]);

  const dateRangeSql = airport && iata && hasTable
    ? `SELECT MIN(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS MIN_DATE, MAX(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS MAX_DATE
       FROM ${db}.TSA_THROUGHPUT WHERE UPPER(airport_code) = '${iata}' AND TRY_TO_DATE(date, 'MM/DD/YYYY') IS NOT NULL`
    : '';
  const { data: dateRangeRows } = useSfQuery(dateRangeSql, airport, 'PUBLIC', [iata, hasTable]);

  const dailySql = airport && iata && hasTable
    ? `SELECT TRY_TO_DATE(date, 'MM/DD/YYYY') AS TSA_DATE,
             SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS TOTAL_PAX,
             COUNT(DISTINCT checkpoint) AS CHECKPOINT_COUNT
       FROM ${db}.TSA_THROUGHPUT
       WHERE UPPER(airport_code) = '${iata}'
         AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY TSA_DATE ORDER BY TSA_DATE`
    : '';
  const { data: dailyData } = useSfQuery(dailySql, airport, 'PUBLIC', [iata, hasTable, dateFrom, dateTo]);

  const hourlySql = airport && iata && hasTable
    ? `SELECT TRY_TO_NUMBER(hour_of_day) AS HOUR_OF_DAY,
             SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS TOTAL_PAX
       FROM ${db}.TSA_THROUGHPUT
       WHERE UPPER(airport_code) = '${iata}'
         AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
         AND TRY_TO_NUMBER(hour_of_day) IS NOT NULL
       GROUP BY HOUR_OF_DAY ORDER BY HOUR_OF_DAY`
    : '';
  const { data: hourlyData } = useSfQuery(hourlySql, airport, 'PUBLIC', [iata, hasTable, dateFrom, dateTo]);

  const checkpointSql = airport && iata && hasTable
    ? `SELECT checkpoint AS CHECKPOINT,
             SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS TOTAL_PAX
       FROM ${db}.TSA_THROUGHPUT
       WHERE UPPER(airport_code) = '${iata}'
         AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
         AND checkpoint IS NOT NULL AND checkpoint != ''
       GROUP BY CHECKPOINT ORDER BY TOTAL_PAX DESC`
    : '';
  const { data: checkpointData } = useSfQuery(checkpointSql, airport, 'PUBLIC', [iata, hasTable, dateFrom, dateTo]);

  const heatmapSql = airport && iata && hasTable
    ? `SELECT TRY_TO_NUMBER(hour_of_day) AS HOUR,
             DAYOFWEEK(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS DAY_OF_WEEK,
             SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS TOTAL_PAX
       FROM ${db}.TSA_THROUGHPUT
       WHERE UPPER(airport_code) = '${iata}'
         AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
         AND TRY_TO_NUMBER(hour_of_day) IS NOT NULL
       GROUP BY HOUR, DAY_OF_WEEK ORDER BY DAY_OF_WEEK, HOUR`
    : '';
  const { data: heatmapData } = useSfQuery(heatmapSql, airport, 'PUBLIC', [iata, hasTable, dateFrom, dateTo]);

  const rawSql = airport && iata && hasTable
    ? `SELECT TRY_TO_DATE(date, 'MM/DD/YYYY') AS DATE,
             hour_of_day AS HOUR,
             checkpoint AS CHECKPOINT,
             TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0) AS PASSENGERS,
             airport_name AS AIRPORT_NAME, city AS CITY, state AS STATE
       FROM ${db}.TSA_THROUGHPUT
       WHERE UPPER(airport_code) = '${iata}'
         AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       ORDER BY DATE DESC, HOUR LIMIT 1000`
    : '';
  const { data: rawData } = useSfQuery(rawSql, airport, 'PUBLIC', [iata, hasTable, dateFrom, dateTo]);

  const totalPax = useMemo(() => dailyData.reduce((s, r: any) => s + (Number(r.TOTAL_PAX) || 0), 0), [dailyData]);
  const numDays = useMemo(() => new Set(dailyData.map((r: any) => r.TSA_DATE)).size, [dailyData]);
  const dailyAvg = numDays > 0 ? Math.round(totalPax / numDays) : 0;
  const maxCheckpoints = useMemo(() => dailyData.reduce((m, r: any) => Math.max(m, Number(r.CHECKPOINT_COUNT) || 0), 0), [dailyData]);
  const peakHour = useMemo(() => {
    if (!hourlyData.length) return '—';
    let best = hourlyData[0] as any;
    for (const r of hourlyData) if ((r as any).TOTAL_PAX > best.TOTAL_PAX) best = r;
    return `${String(best.HOUR_OF_DAY).padStart(2, '0')}:00`;
  }, [hourlyData]);

  const heatmapGrid = useMemo(() => {
    const grid: Record<string, number> = {};
    let max = 0;
    for (const r of heatmapData) {
      const row = r as any;
      const key = `${row.DAY_OF_WEEK}-${row.HOUR}`;
      grid[key] = Number(row.TOTAL_PAX) || 0;
      if (grid[key] > max) max = grid[key];
    }
    return { grid, max };
  }, [heatmapData]);

  const mapLayers = useMemo(() => {
    if (!geoData.length || !meta) return [];
    const maxPax = Math.max(...geoData.map((r: any) => Number(r.TOTAL_PAX) || 0), 1);
    const layers: any[] = [];

    const features: any[] = [];
    const seen = new Set<string>();
    for (const row of geoData) {
      const r = row as any;
      if (!r.GEOJSON || r.MATCH_TYPE !== 'matched') continue;
      const key = r.TERMINAL_NAME || r.CHECKPOINT;
      if (seen.has(key)) continue;
      seen.add(key);
      try {
        const geom = JSON.parse(r.GEOJSON);
        const norm = (Number(r.TOTAL_PAX) || 0) / maxPax;
        const color = intensityColor(norm);
        features.push({
          type: 'Feature',
          geometry: geom,
          properties: { name: r.TERMINAL_NAME || '', pax: fmtNum(Number(r.TOTAL_PAX) || 0), color: [color[0], color[1], color[2], 100] },
        });
      } catch { /* skip bad geojson */ }
    }
    if (features.length) {
      layers.push(new GeoJsonLayer({
        id: 'tsa-terminals',
        data: { type: 'FeatureCollection', features },
        pickable: true,
        stroked: true,
        filled: true,
        getFillColor: (f: any) => f.properties.color,
        getLineColor: [200, 200, 200, 180],
        getLineWidth: 2,
        lineWidthMinPixels: 1,
      }));
    }

    const scatterData = geoData.map((r: any) => {
      const pax = Number(r.TOTAL_PAX) || 0;
      const norm = pax / maxPax;
      const color = r.MATCH_TYPE === 'centroid' ? [180, 180, 180, 140] : intensityColor(norm);
      return {
        position: [Number(r.LON), Number(r.LAT)],
        radius: norm * 150 + 30,
        color,
        checkpoint: r.CHECKPOINT,
        pax: fmtNum(pax),
        avg: fmtNum(Number(r.DAILY_AVG) || 0),
        matchType: r.MATCH_TYPE === 'matched' ? 'Terminal Matched' : 'Airport Center',
      };
    });

    layers.push(new ScatterplotLayer({
      id: 'tsa-checkpoints',
      data: scatterData,
      getPosition: (d: any) => d.position,
      getFillColor: (d: any) => d.color,
      getRadius: (d: any) => d.radius,
      radiusMinPixels: 8,
      radiusMaxPixels: 60,
      pickable: true,
      opacity: 0.85,
    }));

    return layers;
  }, [geoData, meta]);

  const [showRaw, setShowRaw] = useState(false);

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;
  if (!hasTable && tableCheck.length > 0) return <div className="page-dashboard"><h2>TSA Checkpoint Throughput</h2><p className="empty-state">TSA throughput data is not available for this airport.</p></div>;
  if (iata && hasTable && dailyData.length === 0 && dateRangeRows.length > 0) {
    const dr = dateRangeRows[0] as any;
    if (!dr.MIN_DATE) return <div className="page-dashboard"><h2>TSA Checkpoint Throughput</h2><p className="empty-state">No TSA throughput records found for airport <strong>{iata}</strong>.</p></div>;
  }

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>TSA Checkpoint Throughput</h2>
      <p style={{ color: 'var(--text-secondary)', marginBottom: 16 }}>Passenger checkpoint throughput from TSA FOIA data</p>

      <div style={{ display: 'flex', gap: 12, marginBottom: 16 }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>From</label>
          <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>To</label>
          <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="Total Passengers" value={fmtNum(totalPax)} />
        <MetricCard label="Daily Average" value={fmtNum(dailyAvg)} />
        <MetricCard label="Peak Hour" value={peakHour} />
        <MetricCard label="Checkpoints" value={fmtNum(maxCheckpoints)} />
      </div>

      {geoData.length > 0 && meta && (
        <div className="chart-card" style={{ marginBottom: 16 }}>
          <h3>Checkpoint Throughput Map</h3>
          <p style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 8 }}>
            Terminal polygons and checkpoint locations sized by passenger throughput. Unmatched checkpoints shown at airport center.
          </p>
          <div style={{ height: 420, position: 'relative' }}>
            <MapView
              layers={mapLayers}
              initialViewState={{
                longitude: Number(meta.LON),
                latitude: Number(meta.LAT),
                zoom: 14,
                pitch: 30,
              }}
              getTooltip={(info: any) => {
                if (!info.object) return null;
                const d = info.object.properties || info.object;
                if (d.checkpoint) {
                  return { html: `<b>${d.checkpoint}</b><br/>Passengers: ${d.pax}<br/>Daily Avg: ${d.avg}<br/>${d.matchType}` };
                }
                if (d.name) {
                  return { html: `<b>${d.name}</b><br/>Passengers: ${d.pax}` };
                }
                return null;
              }}
            />
          </div>
          <div style={{ display: 'flex', gap: 16, marginTop: 8 }}>
            {(() => {
              const matched = geoData.filter((r: any) => r.MATCH_TYPE === 'matched');
              const unmatched = geoData.filter((r: any) => r.MATCH_TYPE === 'centroid');
              const matchedPax = matched.reduce((s: number, r: any) => s + (Number(r.TOTAL_PAX) || 0), 0);
              const unmatchedPax = unmatched.reduce((s: number, r: any) => s + (Number(r.TOTAL_PAX) || 0), 0);
              return (
                <>
                  {matched.length > 0 && (
                    <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                      Terminal Matched: {matched.length} checkpoints ({fmtNum(matchedPax)} pax)
                    </span>
                  )}
                  {unmatched.length > 0 && (
                    <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                      Airport Center: {unmatched.length} checkpoints ({fmtNum(unmatchedPax)} pax)
                    </span>
                  )}
                </>
              );
            })()}
          </div>
        </div>
      )}

      <div className="chart-row">
        <div className="chart-card">
          <h3>Daily Throughput Trend</h3>
          {dailyData.length > 0 ? (
            <ResponsiveContainer width="100%" height={300}>
              <AreaChart data={dailyData}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="TSA_DATE" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip formatter={(v: any) => fmtNum(v)} />
                <Area type="monotone" dataKey="TOTAL_PAX" stroke="#29B5E8" fill="rgba(41,181,232,0.2)" name="Passengers" />
              </AreaChart>
            </ResponsiveContainer>
          ) : <p className="empty-state">No data</p>}
        </div>
        <div className="chart-card">
          <h3>Throughput by Hour of Day</h3>
          {hourlyData.length > 0 ? (
            <ResponsiveContainer width="100%" height={300}>
              <BarChart data={hourlyData}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="HOUR_OF_DAY" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip formatter={(v: any) => fmtNum(v)} />
                <Bar dataKey="TOTAL_PAX" fill="#29B5E8" radius={[4, 4, 0, 0]} name="Passengers" />
              </BarChart>
            </ResponsiveContainer>
          ) : <p className="empty-state">No data</p>}
        </div>
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Throughput by Checkpoint</h3>
          {checkpointData.length > 0 ? (
            <ResponsiveContainer width="100%" height={Math.max(250, checkpointData.length * 28 + 30)}>
              <BarChart data={checkpointData} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis type="number" tick={{ fontSize: 10 }} />
                <YAxis type="category" dataKey="CHECKPOINT" tick={{ fontSize: 10 }} width={80} />
                <Tooltip formatter={(v: any) => fmtNum(v)} />
                <Bar dataKey="TOTAL_PAX" fill="#0DB048" radius={[0, 4, 4, 0]} name="Passengers" />
              </BarChart>
            </ResponsiveContainer>
          ) : <p className="empty-state">No checkpoint data</p>}
        </div>
        <div className="chart-card">
          <h3>Checkpoint Share</h3>
          {checkpointData.length > 1 ? (
            <ResponsiveContainer width="100%" height={300}>
              <PieChart>
                <Pie data={checkpointData} dataKey="TOTAL_PAX" nameKey="CHECKPOINT" cx="50%" cy="50%"
                     innerRadius={60} outerRadius={110} paddingAngle={2} label={({ CHECKPOINT }: any) => CHECKPOINT}>
                  {checkpointData.map((_: any, i: number) => (
                    <Cell key={i} fill={COLORS_PALETTE[i % COLORS_PALETTE.length]} />
                  ))}
                </Pie>
                <Tooltip formatter={(v: any) => fmtNum(v)} />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          ) : <p className="empty-state">{checkpointData.length === 1 ? 'Single checkpoint' : 'No data'}</p>}
        </div>
      </div>

      {heatmapData.length > 0 && (
        <div className="chart-card" style={{ marginTop: 16 }}>
          <h3>Throughput Heatmap (Day of Week x Hour)</h3>
          <p style={{ fontSize: 12, color: 'var(--text-secondary)', marginBottom: 8 }}>
            Color intensity shows passenger count: darker = more passengers
          </p>
          <div style={{ overflowX: 'auto' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '60px repeat(24, 1fr)', gap: 2, minWidth: 700 }}>
              <div />
              {Array.from({ length: 24 }, (_, h) => (
                <div key={h} style={{ fontSize: 10, textAlign: 'center', color: 'var(--text-secondary)' }}>
                  {String(h).padStart(2, '0')}
                </div>
              ))}
              {DAY_NAMES.map((day, di) => (
                <>
                  <div key={`label-${di}`} style={{ fontSize: 11, display: 'flex', alignItems: 'center', color: 'var(--text-secondary)' }}>
                    {day}
                  </div>
                  {Array.from({ length: 24 }, (_, h) => {
                    const val = heatmapGrid.grid[`${di}-${h}`] || 0;
                    return (
                      <div key={`${di}-${h}`} title={`${day} ${String(h).padStart(2, '0')}:00 — ${fmtNum(val)} pax`}
                           style={{
                             backgroundColor: heatColor(val, heatmapGrid.max),
                             borderRadius: 3,
                             height: 28,
                             cursor: 'default',
                           }} />
                    );
                  })}
                </>
              ))}
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, fontSize: 11, color: 'var(--text-secondary)' }}>
            <span>Low</span>
            <div style={{ width: 120, height: 10, borderRadius: 4, background: 'linear-gradient(to right, rgb(26,35,50), rgb(41,181,232), rgb(229,161,0))' }} />
            <span>High</span>
          </div>
        </div>
      )}

      <div className="chart-card" style={{ marginTop: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', cursor: 'pointer' }}
             onClick={() => setShowRaw(!showRaw)}>
          <h3>Raw Data</h3>
          <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>{showRaw ? '▲ Collapse' : '▼ Expand'}</span>
        </div>
        {showRaw && <DataTable data={rawData} maxRows={1000} />}
      </div>
    </div>
  );
}
