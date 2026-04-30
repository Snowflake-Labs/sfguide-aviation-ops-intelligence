import { useState, useMemo } from 'react';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum, fmtDec, fmtPct, fmtChartDate } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import {
  LineChart, Line, BarChart, Bar, AreaChart, Area, PieChart, Pie, Cell,
  XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from 'recharts';

const COLORS = ['#29B5E8', '#0DB048', '#E5A100', '#E5484D', '#9B59B6', '#6E7681'];

export default function Monitoring() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const [lookbackDays, setLookbackDays] = useState(14);

  const freshnessSql = airport
    ? `SELECT DATEDIFF('minute', MAX(TIMESTAMP), SYSDATE()) AS minutes_ago,
              COUNT(*) AS pts_24h,
              COUNT(DISTINCT ICAO_HEX) AS aircraft_24h
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('hour', -24, SYSDATE())`
    : '';
  const { data: freshnessRows, loading } = useSfQuery(freshnessSql, airport, 'PUBLIC');
  const freshness = freshnessRows[0] as any || {};

  const matchSql = airport
    ? `SELECT ROUND(100.0 * COUNT_IF(SCHEDULE_FLIGHT_KEY IS NOT NULL) / NULLIF(COUNT(*), 0), 1) AS match_rate
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('hour', -24, SYSDATE())`
    : '';
  const { data: matchRows } = useSfQuery(matchSql, airport, 'PUBLIC');
  const matchRate = (matchRows[0] as any)?.MATCH_RATE ?? '—';

  const matchDistSql = airport
    ? `SELECT COALESCE(MATCH_METHOD, 'Unmatched') AS METHOD, COUNT(*) AS CNT
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('day', -${lookbackDays}, SYSDATE())
       GROUP BY 1 ORDER BY CNT DESC`
    : '';
  const { data: matchDist } = useSfQuery(matchDistSql, airport, 'PUBLIC', [lookbackDays]);

  const hourlyIngestSql = airport
    ? `SELECT DATE_TRUNC('hour', TIMESTAMP) AS HR, COUNT(*) AS POINTS
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('hour', -48, SYSDATE())
       GROUP BY 1 ORDER BY 1`
    : '';
  const { data: hourlyIngest } = useSfQuery(hourlyIngestSql, airport, 'PUBLIC', [lookbackDays]);

  const dailyVolSql = airport
    ? `SELECT TO_DATE(TIMESTAMP) AS DT, COUNT(*) AS POINTS, COUNT(DISTINCT ICAO_HEX) AS AIRCRAFT
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('day', -${lookbackDays}, SYSDATE())
       GROUP BY 1 ORDER BY 1`
    : '';
  const { data: dailyVol } = useSfQuery(dailyVolSql, airport, 'PUBLIC', [lookbackDays]);

  const matchTrendSql = airport
    ? `SELECT TO_DATE(TIMESTAMP) AS DT,
              ROUND(100.0 * COUNT_IF(SCHEDULE_FLIGHT_KEY IS NOT NULL) / NULLIF(COUNT(*), 0), 1) AS MATCH_RATE
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE TIMESTAMP >= DATEADD('day', -${lookbackDays}, SYSDATE())
       GROUP BY 1 ORDER BY 1`
    : '';
  const { data: matchTrend } = useSfQuery(matchTrendSql, airport, 'PUBLIC', [lookbackDays]);

  const tasksSql = airport
    ? `SELECT NAME, STATE, SCHEDULE, LAST_COMMITTED_ON
       FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
         SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
         RESULT_LIMIT => 50
       ))
       WHERE DATABASE_NAME = '${airport}' AND SCHEMA_NAME = 'PUBLIC'
       QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY SCHEDULED_TIME DESC) = 1
       ORDER BY NAME`
    : '';
  const { data: tasksData } = useSfQuery(tasksSql, airport, 'PUBLIC', [lookbackDays]);

  const lastRefreshSql = airport
    ? `SELECT TABLE_NAME, LAST_REFRESHED_AT, STATUS, ROW_COUNT_24H
       FROM ${db}.HELPER_MONITOR_LAST_REFRESH
       ORDER BY LAST_REFRESHED_AT DESC`
    : '';
  const { data: lastRefresh } = useSfQuery(lastRefreshSql, airport, 'PUBLIC');

  const qaSql = airport
    ? `SELECT METRIC_DATE, METRIC_NAME, METRIC_VALUE
       FROM ${db}.HELPER_QA_COUNTS_DAILY
       ORDER BY METRIC_DATE DESC, METRIC_NAME LIMIT 100`
    : '';
  const { data: qaData } = useSfQuery(qaSql, airport, 'PUBLIC');

  const ingestSql = airport
    ? `SELECT RUN_ID, AIRPORT_CODE, WINDOW_START, WINDOW_END,
              ROWS_RAW, ROWS_INSERTED, ROWS_DEDUPED, STATUS, ERROR_MESSAGE
       FROM ${db}.HELPER_INGEST_AUDIT
       ORDER BY WINDOW_END DESC LIMIT 20`
    : '';
  const { data: ingestData } = useSfQuery(ingestSql, airport, 'PUBLIC');

  const taskSummary = useMemo(() => {
    const running = tasksData.filter((t: any) => t.STATE === 'SUCCEEDED').length;
    const total = tasksData.length;
    return { running, total };
  }, [tasksData]);

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>Monitoring</h2>
      <div style={{ display: 'flex', gap: 12, marginBottom: 16, alignItems: 'flex-end' }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Lookback: {lookbackDays} days</label>
          <input type="range" min={1} max={90} value={lookbackDays}
            onChange={e => setLookbackDays(Number(e.target.value))} style={{ width: 160 }} />
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="Flight Match Rate" value={loading ? '...' : `${matchRate}%`} />
        <MetricCard label="Aircraft (24h)" value={fmtNum(freshness.AIRCRAFT_24H)} />
        <MetricCard label="Data Freshness" value={freshness.MINUTES_AGO != null ? `${freshness.MINUTES_AGO} min ago` : '—'} />
        <MetricCard label="Points (24h)" value={fmtNum(freshness.PTS_24H)} />
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Daily Match Rate</h3>
          <ResponsiveContainer width="100%" height={200}>
            <LineChart data={matchTrend}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
              <YAxis domain={[0, 100]} tick={{ fontSize: 10 }} />
              <Tooltip />
              <Line type="monotone" dataKey="MATCH_RATE" stroke="#29B5E8" dot={false} strokeWidth={2} name="Match Rate %" />
            </LineChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Match Method Distribution</h3>
          {matchDist.length > 0 && (
            <ResponsiveContainer width="100%" height={200}>
              <PieChart>
                <Pie data={matchDist} dataKey="CNT" nameKey="METHOD" cx="50%" cy="50%"
                     innerRadius={40} outerRadius={80} paddingAngle={2}>
                  {matchDist.map((_: any, i: number) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          )}
        </div>
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Hourly Ingestion (48h)</h3>
          <ResponsiveContainer width="100%" height={200}>
            <AreaChart data={hourlyIngest}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="HR" tick={{ fontSize: 9 }} tickFormatter={(v: string) => v ? v.substring(11, 16) : ''} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Area type="monotone" dataKey="POINTS" stroke="#29B5E8" fill="#29B5E8" fillOpacity={0.3} name="Points/hr" />
            </AreaChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Daily ADS-B Points</h3>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={dailyVol}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Bar dataKey="POINTS" fill="#29B5E8" radius={[4, 4, 0, 0]} name="Points" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="chart-card" style={{ marginBottom: 16 }}>
        <h3>Daily Unique Aircraft</h3>
        <ResponsiveContainer width="100%" height={200}>
          <LineChart data={dailyVol}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
            <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
            <YAxis tick={{ fontSize: 10 }} />
            <Tooltip />
            <Line type="monotone" dataKey="AIRCRAFT" stroke="#0DB048" strokeWidth={2} name="Aircraft" />
          </LineChart>
        </ResponsiveContainer>
      </div>

      {tasksData.length > 0 && (
        <div className="chart-card" style={{ marginBottom: 16 }}>
          <h3>Task Status ({taskSummary.running}/{taskSummary.total} succeeded)</h3>
          <DataTable data={tasksData} maxRows={50} />
        </div>
      )}

      <div className="chart-row">
        <div className="chart-card">
          <h3>Last Refresh Status</h3>
          <DataTable data={lastRefresh} maxRows={50} />
        </div>
        <div className="chart-card">
          <h3>QA Counts</h3>
          <DataTable data={qaData} maxRows={50} />
        </div>
      </div>

      <div className="chart-card" style={{ marginTop: 16 }}>
        <h3>Ingestion Audit</h3>
        <DataTable data={ingestData} maxRows={20} />
      </div>
    </div>
  );
}
