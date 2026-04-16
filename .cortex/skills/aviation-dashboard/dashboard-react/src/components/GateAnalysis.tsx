import { useState } from 'react';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum, fmtDec } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid,
} from 'recharts';

export default function GateAnalysis() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);

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
  const { data: gateData } = useSfQuery(gateSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const airlineSql = airport
    ? `SELECT airline_code AS AIRLINE, SUM(dwell_minutes) AS DWELL_MIN, SUM(flights) AS FLIGHTS
       FROM ${db}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY 1 ORDER BY DWELL_MIN DESC LIMIT 15`
    : '';
  const { data: airlineData } = useSfQuery(airlineSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const topFlightsSql = airport
    ? `SELECT flight_number AS FLIGHT, airline_name AS AIRLINE, service_date AS DATE,
              gate_name AS GATE, ROUND(dwell_minutes, 1) AS DWELL_MIN
       FROM ${db}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       ORDER BY dwell_minutes DESC LIMIT 20`
    : '';
  const { data: topFlights } = useSfQuery(topFlightsSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>Gate Analysis</h2>
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

      <div className="chart-card">
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

      <div className="chart-card" style={{ marginTop: 16 }}>
        <h3>Top 20 Flights by Dwell Time</h3>
        <DataTable data={topFlights} maxRows={20} />
      </div>
    </div>
  );
}
