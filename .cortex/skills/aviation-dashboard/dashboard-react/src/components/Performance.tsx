import { useState } from 'react';
import MetricCard from '../shared/MetricCard';
import { fmtNum, fmtDec, fmtPct, fmtChartDate } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import {
  LineChart, Line, BarChart, Bar,
  XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Legend,
} from 'recharts';

export default function Performance() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const monthAgo = new Date(Date.now() - 30 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(monthAgo);
  const [dateTo, setDateTo] = useState(today);
  const [airline, setAirline] = useState('ALL');

  const airlinesSql = airport
    ? `SELECT DISTINCT airline_name FROM ${db}.V_AIR_OPS_DAILY_KPIS
       WHERE airline_name IS NOT NULL ORDER BY 1`
    : '';
  const { data: airlinesList } = useSfQuery(airlinesSql, airport, 'PUBLIC');

  const kpiFilter = airline === 'ALL' ? '' : ` AND airline_name = '${airline}'`;
  const kpiSql = airport
    ? `SELECT service_date AS DT, airline_name AS AIRLINE,
              ops AS OPS,
              med_taxi_out_min AS TAXI_OUT,
              med_taxi_in_min AS TAXI_IN,
              med_dep_runway_occ_min AS DEP_RUNWAY,
              med_arr_runway_occ_min AS ARR_RUNWAY,
              on_time_dep_out_15m_rate AS OTP_DEP,
              on_time_arr_in_15m_rate AS OTP_ARR,
              head_to_head AS H2H
       FROM ${db}.V_AIR_OPS_DAILY_KPIS
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE${kpiFilter}
       ORDER BY service_date`
    : '';
  const { data: kpiData, loading } = useSfQuery(kpiSql, airport, 'PUBLIC', [dateFrom, dateTo, airline]);

  const latest = kpiData.length ? kpiData[kpiData.length - 1] as any : null;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>Performance</h2>
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
          <select className="form-select" value={airline} onChange={e => setAirline(e.target.value)}>
            <option value="ALL">All Airlines</option>
            {airlinesList.map((a: any) => (
              <option key={a.AIRLINE_NAME} value={a.AIRLINE_NAME}>{a.AIRLINE_NAME}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="Operations (Last Day)" value={loading ? '...' : fmtNum(latest?.OPS)} />
        <MetricCard label="Median Taxi-out" value={latest ? `${fmtDec(latest.TAXI_OUT)} min` : '—'} />
        <MetricCard label="Median Taxi-in" value={latest ? `${fmtDec(latest.TAXI_IN)} min` : '—'} />
        <MetricCard label="On-time Arrivals" value={latest?.OTP_ARR != null ? `${fmtDec(Number(latest.OTP_ARR) * 100)}%` : '—'} />
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Median Taxi Times</h3>
          <ResponsiveContainer width="100%" height={250}>
            <LineChart data={kpiData}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Legend wrapperStyle={{ fontSize: 11 }} />
              <Line type="monotone" dataKey="TAXI_OUT" stroke="#29B5E8" dot={false} strokeWidth={2} name="Taxi-out (min)" />
              <Line type="monotone" dataKey="TAXI_IN" stroke="#0DB048" dot={false} strokeWidth={2} name="Taxi-in (min)" />
            </LineChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>On-time Rates</h3>
          <ResponsiveContainer width="100%" height={250}>
            <LineChart data={kpiData.map((d: any) => ({
              ...d,
              OTP_DEP_PCT: d.OTP_DEP != null ? Number(d.OTP_DEP) * 100 : null,
              OTP_ARR_PCT: d.OTP_ARR != null ? Number(d.OTP_ARR) * 100 : null,
            }))}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
              <YAxis domain={[0, 100]} tick={{ fontSize: 10 }} />
              <Tooltip />
              <Legend wrapperStyle={{ fontSize: 11 }} />
              <Line type="monotone" dataKey="OTP_DEP_PCT" stroke="#E5A100" dot={false} strokeWidth={2} name="Dep OTP %" />
              <Line type="monotone" dataKey="OTP_ARR_PCT" stroke="#0DB048" dot={false} strokeWidth={2} name="Arr OTP %" />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="chart-card" style={{ marginTop: 16 }}>
        <h3>Head-to-Head Days</h3>
        <ResponsiveContainer width="100%" height={150}>
          <BarChart data={kpiData}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
            <XAxis dataKey="DT" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
            <YAxis tick={{ fontSize: 10 }} domain={[0, 1]} />
            <Tooltip />
            <Bar dataKey="H2H" fill="#E5484D" radius={[4, 4, 0, 0]} name="Head-to-Head" />
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
