import { useState, useMemo } from 'react';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import HeatmapGrid, { DOW_LABELS } from '../shared/HeatmapGrid';
import { fmtNum, fmtDec } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from 'recharts';

const COLORS = ['#29B5E8', '#0DB048', '#E5A100', '#E5484D', '#9B59B6', '#F39C12', '#1ABC9C', '#6E7681'];

function naturalSort(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
}

export default function GateAnalysis() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);
  const [airlineFilter, setAirlineFilter] = useState('');

  const airlineListSql = airport
    ? `SELECT DISTINCT airline_code AS AIRLINE FROM ${db}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE AND airline_code IS NOT NULL
       ORDER BY 1`
    : '';
  const { data: airlineList } = useSfQuery(airlineListSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const airlineClause = airlineFilter ? `AND airline_code = '${airlineFilter}'` : '';

  const fillSql = airport
    ? `WITH ops AS (
         SELECT COUNT(DISTINCT ground_session_id) AS total FROM ${db}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
         WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       ),
       gated AS (
         SELECT COUNT(DISTINCT ground_session_id) AS gated FROM ${db}.GATE_ANALYSIS_FLIGHT_GATE_TIME
         WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       )
       SELECT ops.total, gated.gated, ROUND(100.0 * gated.gated / NULLIF(ops.total, 0), 1) AS fill_rate
       FROM ops, gated`
    : '';
  const { data: fillRows } = useSfQuery(fillSql, airport, 'PUBLIC', [dateFrom, dateTo]);
  const fill = fillRows[0] as any || {};

  const gateSql = airport
    ? `SELECT gate_name AS GATE, SUM(dwell_minutes) AS DWELL_MIN, SUM(flights) AS FLIGHTS
       FROM ${db}.GATE_ANALYSIS_GATE_UTIL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY 1 ORDER BY DWELL_MIN DESC LIMIT 20`
    : '';
  const { data: gateDataRaw } = useSfQuery(gateSql, airport, 'PUBLIC', [dateFrom, dateTo]);
  const gateData = useMemo(() => [...gateDataRaw].sort((a: any, b: any) => naturalSort(a.GATE || '', b.GATE || '')), [gateDataRaw]);

  const gateAirlineStackSql = airport
    ? `SELECT gate_name AS GATE, airline_code AS AIRLINE, SUM(dwell_minutes) AS DWELL_MIN
       FROM ${db}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${airlineClause}
       GROUP BY 1, 2
       ORDER BY DWELL_MIN DESC`
    : '';
  const { data: gateAirlineRaw } = useSfQuery(gateAirlineStackSql, airport, 'PUBLIC', [dateFrom, dateTo, airlineClause]);

  const { stackedData, stackedAirlines } = useMemo(() => {
    const gateMap = new Map<string, Record<string, any>>();
    const airlines = new Set<string>();
    gateAirlineRaw.forEach((r: any) => {
      airlines.add(r.AIRLINE);
      const entry = gateMap.get(r.GATE) || { GATE: r.GATE };
      entry[r.AIRLINE] = (entry[r.AIRLINE] || 0) + Number(r.DWELL_MIN || 0);
      gateMap.set(r.GATE, entry);
    });
    const sorted = Array.from(gateMap.values())
      .sort((a, b) => {
        const aTotal = Object.entries(a).filter(([k]) => k !== 'GATE').reduce((s, [, v]) => s + (v as number), 0);
        const bTotal = Object.entries(b).filter(([k]) => k !== 'GATE').reduce((s, [, v]) => s + (v as number), 0);
        return bTotal - aTotal;
      })
      .slice(0, 15);
    return { stackedData: sorted, stackedAirlines: Array.from(airlines).slice(0, 8) };
  }, [gateAirlineRaw]);

  const airlineSql = airport
    ? `SELECT airline_code AS AIRLINE, SUM(dwell_minutes) AS DWELL_MIN, SUM(flights) AS FLIGHTS
       FROM ${db}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${airlineClause}
       GROUP BY 1 ORDER BY DWELL_MIN DESC LIMIT 15`
    : '';
  const { data: airlineData } = useSfQuery(airlineSql, airport, 'PUBLIC', [dateFrom, dateTo, airlineClause]);

  const heatmapSql = airport
    ? `SELECT DAYOFWEEK(date) AS DOW, gate_name AS GATE, SUM(dwell_minutes) AS DWELL
       FROM ${db}.GATE_ANALYSIS_GATE_UTIL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY 1, 2`
    : '';
  const { data: heatmapRaw } = useSfQuery(heatmapSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const { heatmapData, gateLabels } = useMemo(() => {
    const gates = new Set<string>();
    const data = heatmapRaw.map((d: any) => {
      gates.add(d.GATE);
      return { row: DOW_LABELS[Number(d.DOW)], col: d.GATE, value: Number(d.DWELL) || 0 };
    });
    return { heatmapData: data, gateLabels: Array.from(gates).sort(naturalSort).slice(0, 20) };
  }, [heatmapRaw]);

  const topFlightsSql = airport
    ? `SELECT flight_number AS FLIGHT, airline_name AS AIRLINE, service_date AS DATE,
              gate_name AS GATE, ROUND(dwell_minutes, 1) AS DWELL_MIN
       FROM ${db}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${airlineClause}
       ORDER BY dwell_minutes DESC LIMIT 20`
    : '';
  const { data: topFlights } = useSfQuery(topFlightsSql, airport, 'PUBLIC', [dateFrom, dateTo, airlineClause]);

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>Gate Analysis</h2>
      <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap' }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>From</label>
          <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>To</label>
          <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Airline</label>
          <select className="form-select" value={airlineFilter} onChange={e => setAirlineFilter(e.target.value)}>
            <option value="">All Airlines</option>
            {airlineList.map((r: any) => <option key={r.AIRLINE} value={r.AIRLINE}>{r.AIRLINE}</option>)}
          </select>
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="Ground Sessions" value={fmtNum(fill.TOTAL)} />
        <MetricCard label="With Gate Assigned" value={fmtNum(fill.GATED)} />
        <MetricCard label="Gate Fill Rate" value={fill.FILL_RATE != null ? `${fill.FILL_RATE}%` : '—'} />
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Gate Utilization (Dwell Minutes)</h3>
          <ResponsiveContainer width="100%" height={Math.max(250, gateData.length * 28 + 30)}>
            <BarChart data={gateData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="GATE" tick={{ fontSize: 10 }} width={60} />
              <Tooltip />
              <Bar dataKey="DWELL_MIN" fill="#29B5E8" radius={[0, 4, 4, 0]} name="Dwell (min)" />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Airline Utilization (Dwell Minutes)</h3>
          <ResponsiveContainer width="100%" height={Math.max(250, airlineData.length * 28 + 30)}>
            <BarChart data={airlineData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="AIRLINE" tick={{ fontSize: 10 }} width={50} />
              <Tooltip />
              <Bar dataKey="DWELL_MIN" fill="#0DB048" radius={[0, 4, 4, 0]} name="Dwell (min)" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      {stackedData.length > 0 && (
        <div className="chart-card" style={{ marginTop: 16 }}>
          <h3>Gate × Airline Stacked (Dwell Minutes)</h3>
          <ResponsiveContainer width="100%" height={Math.max(300, stackedData.length * 28 + 40)}>
            <BarChart data={stackedData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="GATE" tick={{ fontSize: 10 }} width={60} />
              <Tooltip />
              <Legend />
              {stackedAirlines.map((al, i) => (
                <Bar key={al} dataKey={al} stackId="a" fill={COLORS[i % COLORS.length]} />
              ))}
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      <div className="chart-card" style={{ marginTop: 16 }}>
        <h3>Gate Utilization (Flight Count)</h3>
        <ResponsiveContainer width="100%" height={Math.max(250, gateData.length * 28 + 30)}>
          <BarChart data={gateData} layout="vertical">
            <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
            <XAxis type="number" tick={{ fontSize: 10 }} />
            <YAxis type="category" dataKey="GATE" tick={{ fontSize: 10 }} width={60} />
            <Tooltip />
            <Bar dataKey="FLIGHTS" fill="#E5A100" radius={[0, 4, 4, 0]} name="Flights" />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {heatmapData.length > 0 && gateLabels.length > 0 && (
        <div className="chart-card" style={{ marginTop: 16 }}>
          <h3>Gate Usage Heatmap (Day of Week × Gate)</h3>
          <HeatmapGrid data={heatmapData} rowLabels={DOW_LABELS} colLabels={gateLabels} />
        </div>
      )}

      <div className="chart-card" style={{ marginTop: 16 }}>
        <h3>Top 20 Flights by Dwell Time</h3>
        <DataTable data={topFlights} maxRows={20} />
      </div>
    </div>
  );
}
