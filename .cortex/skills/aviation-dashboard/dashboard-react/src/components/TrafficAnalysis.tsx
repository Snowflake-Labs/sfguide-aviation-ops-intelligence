import { useState, useMemo } from 'react';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import HeatmapGrid, { DOW_LABELS, HOUR_LABELS } from '../shared/HeatmapGrid';
import { fmtNum, fmtDec, fmtChartDate } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import VehicleTypeFilter, { useVehicleTypeFilter } from '../shared/VehicleTypeFilter';
import {
  BarChart, Bar, LineChart, Line, PieChart, Pie, Cell,
  XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid,
} from 'recharts';

const COLORS = ['#29B5E8', '#0DB048', '#E5A100', '#E5484D', '#6E7681', '#9B59B6', '#F39C12', '#1ABC9C'];
const DOW_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export default function TrafficAnalysis() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);
  const [granularity, setGranularity] = useState<'daily' | 'weekly'>('daily');
  const [delayThreshold, setDelayThreshold] = useState(15);
  const { selected: vtSelected, setSelected: setVtSelected, sqlFilter: vehicleSqlFilter } = useVehicleTypeFilter();

  const dailySql = airport
    ? granularity === 'daily'
      ? `SELECT DATE, SUM(UNIQUE_AIRCRAFT) AS AIRCRAFT, SUM(UNIQUE_FLIGHTS) AS FLIGHTS,
                SUM(TOTAL_RECORDS) AS RECORDS
         FROM ${db}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY
         WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
         GROUP BY 1 ORDER BY 1`
      : `SELECT DATE_TRUNC('week', DATE) AS DATE, SUM(UNIQUE_AIRCRAFT) AS AIRCRAFT, SUM(UNIQUE_FLIGHTS) AS FLIGHTS,
                SUM(TOTAL_RECORDS) AS RECORDS
         FROM ${db}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY
         WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
         GROUP BY 1 ORDER BY 1`
    : '';
  const { data: dailyData, loading } = useSfQuery(dailySql, airport, 'PUBLIC', [dateFrom, dateTo, granularity, vehicleSqlFilter]);

  const hourlySql = airport
    ? `SELECT HOUR, SUM(AIRCRAFT_COUNT) AS AIRCRAFT
       FROM ${db}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
       GROUP BY 1 ORDER BY 1`
    : '';
  const { data: hourlyData } = useSfQuery(hourlySql, airport, 'PUBLIC', [dateFrom, dateTo, vehicleSqlFilter]);

  const dowSql = airport
    ? `SELECT DAYOFWEEK(DATE) AS DOW, SUM(UNIQUE_AIRCRAFT) AS AIRCRAFT
       FROM ${db}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
       GROUP BY 1 ORDER BY 1`
    : '';
  const { data: dowRaw } = useSfQuery(dowSql, airport, 'PUBLIC', [dateFrom, dateTo, vehicleSqlFilter]);
  const dowData = useMemo(() => dowRaw.map((d: any) => ({ DOW: DOW_SHORT[Number(d.DOW)], AIRCRAFT: Number(d.AIRCRAFT) || 0 })), [dowRaw]);

  const heatmapSql = airport
    ? `SELECT DAYOFWEEK(DATE) AS DOW, HOUR, SUM(AIRCRAFT_COUNT) AS CNT
       FROM ${db}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
       GROUP BY 1, 2`
    : '';
  const { data: heatmapRaw } = useSfQuery(heatmapSql, airport, 'PUBLIC', [dateFrom, dateTo, vehicleSqlFilter]);
  const heatmapData = useMemo(() =>
    heatmapRaw.map((d: any) => ({ row: DOW_LABELS[Number(d.DOW)], col: String(Number(d.HOUR)), value: Number(d.CNT) || 0 })),
    [heatmapRaw]);

  const airlineSql = airport
    ? `SELECT AIRLINE_CODE AS AIRLINE, SUM(FLIGHT_COUNT) AS FLIGHTS, SUM(AIRCRAFT_COUNT) AS AIRCRAFT
       FROM ${db}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${vehicleSqlFilter}
       GROUP BY 1 ORDER BY FLIGHTS DESC LIMIT 15`
    : '';
  const { data: airlineData } = useSfQuery(airlineSql, airport, 'PUBLIC', [dateFrom, dateTo, vehicleSqlFilter]);

  const delaySql = airport
    ? `SELECT AIRLINE, SUM(TOTAL_DELAY_MINUTES) AS DELAY_MIN, SUM(DELAYED_FLIGHTS) AS DELAYED,
              SUM(TOTAL_EARLY_MINUTES) AS EARLY_MIN, SUM(EARLY_FLIGHTS) AS EARLY
       FROM ${db}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY
       WHERE DATE BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY 1 ORDER BY DELAY_MIN DESC LIMIT 15`
    : '';
  const { data: delayData } = useSfQuery(delaySql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const totalAircraft = dailyData.reduce((a, d: any) => a + (Number(d.AIRCRAFT) || 0), 0);
  const totalFlights = dailyData.reduce((a, d: any) => a + (Number(d.FLIGHTS) || 0), 0);
  const peakHour = hourlyData.length
    ? hourlyData.reduce((best: any, d: any) => (Number(d.AIRCRAFT) || 0) > (Number(best.AIRCRAFT) || 0) ? d : best, hourlyData[0])
    : null;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-dashboard" style={{ overflow: 'auto', maxHeight: '100vh' }}>
      <h2>Traffic Analysis</h2>
      <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>From</label>
          <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>To</label>
          <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Granularity</label>
          <select className="form-select" value={granularity} onChange={e => setGranularity(e.target.value as any)}>
            <option value="daily">Daily</option>
            <option value="weekly">Weekly</option>
          </select>
        </div>
        <div className="form-group" style={{ marginBottom: 0 }}>
          <label>Delay Threshold (min)</label>
          <input type="number" className="form-input" style={{ width: 70 }} value={delayThreshold}
            min={1} max={120} onChange={e => setDelayThreshold(Number(e.target.value) || 15)} />
        </div>
        <div style={{ minWidth: 200 }}>
          <VehicleTypeFilter selected={vtSelected} onChange={setVtSelected} />
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="Total Aircraft" value={loading ? '...' : fmtNum(totalAircraft)} />
        <MetricCard label="Total Flights" value={fmtNum(totalFlights)} />
        <MetricCard label="Peak Hour" value={peakHour ? `${peakHour.HOUR}:00` : '—'} subtitle={peakHour ? `${fmtNum(peakHour.AIRCRAFT)} aircraft` : ''} />
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Traffic Trend ({granularity === 'daily' ? 'Daily' : 'Weekly'})</h3>
          <ResponsiveContainer width="100%" height={250}>
            <LineChart data={dailyData}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DATE" tick={{ fontSize: 10 }} tickFormatter={fmtChartDate} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Line type="monotone" dataKey="AIRCRAFT" stroke="#29B5E8" dot={false} strokeWidth={2} name="Aircraft" />
              <Line type="monotone" dataKey="FLIGHTS" stroke="#0DB048" dot={false} strokeWidth={2} name="Flights" />
            </LineChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Aircraft by Hour of Day</h3>
          <ResponsiveContainer width="100%" height={250}>
            <BarChart data={hourlyData}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="HOUR" tick={{ fontSize: 10 }} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Bar dataKey="AIRCRAFT" fill="#29B5E8" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Traffic by Day of Week</h3>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={dowData}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="DOW" tick={{ fontSize: 10 }} />
              <YAxis tick={{ fontSize: 10 }} />
              <Tooltip />
              <Bar dataKey="AIRCRAFT" fill="#9B59B6" radius={[4, 4, 0, 0]} name="Aircraft" />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Activity Heatmap (DoW × Hour)</h3>
          {heatmapData.length > 0 && (
            <HeatmapGrid data={heatmapData} rowLabels={DOW_LABELS} colLabels={HOUR_LABELS} />
          )}
        </div>
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Top Airlines by Flights</h3>
          <ResponsiveContainer width="100%" height={Math.max(200, airlineData.length * 30 + 30)}>
            <BarChart data={airlineData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="AIRLINE" tick={{ fontSize: 11 }} width={50} />
              <Tooltip />
              <Bar dataKey="FLIGHTS" fill="#29B5E8" radius={[0, 4, 4, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Market Share</h3>
          <ResponsiveContainer width="100%" height={250}>
            <PieChart>
              <Pie data={airlineData.slice(0, 8)} dataKey="FLIGHTS" nameKey="AIRLINE" cx="50%" cy="50%"
                   innerRadius={50} outerRadius={100} paddingAngle={2}>
                {airlineData.slice(0, 8).map((_: any, i: number) => (
                  <Cell key={i} fill={COLORS[i % COLORS.length]} />
                ))}
              </Pie>
              <Tooltip />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="chart-row">
        <div className="chart-card">
          <h3>Delays by Airline (minutes)</h3>
          <ResponsiveContainer width="100%" height={Math.max(200, delayData.length * 30 + 30)}>
            <BarChart data={delayData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="AIRLINE" tick={{ fontSize: 11 }} width={50} />
              <Tooltip />
              <Bar dataKey="DELAY_MIN" fill="#E5484D" radius={[0, 4, 4, 0]} name="Delay (min)" />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <div className="chart-card">
          <h3>Early Flights by Airline</h3>
          <ResponsiveContainer width="100%" height={Math.max(200, delayData.length * 30 + 30)}>
            <BarChart data={delayData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis type="number" tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="AIRLINE" tick={{ fontSize: 11 }} width={50} />
              <Tooltip />
              <Bar dataKey="EARLY" fill="#0DB048" radius={[0, 4, 4, 0]} name="Early Flights" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  );
}
