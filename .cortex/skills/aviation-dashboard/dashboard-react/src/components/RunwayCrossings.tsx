import { useState, useMemo } from 'react';
import { H3HexagonLayer } from '@deck.gl/geo-layers';
import { GeoJsonLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum, fmtDec } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Cell } from 'recharts';

export default function RunwayCrossings() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const days = Math.max(1, Math.round((new Date(dateTo).getTime() - new Date(dateFrom).getTime()) / 86400000) + 1);

  const summarySql = airport
    ? `SELECT ROUND(COUNT(DISTINCT flight_key)/${days}) AS avg_flights,
              ROUND(COUNT(*)/${days}) AS avg_crossings,
              ROUND(AVG(duration_s), 1) AS avg_duration,
              ROUND(SUM(duration_s)/60.0/${days}, 1) AS avg_total_min
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE`
    : '';
  const { data: summaryRows } = useSfQuery(summarySql, airport, 'PUBLIC', [dateFrom, dateTo]);
  const summary = summaryRows[0] as any || {};

  const dirSql = airport
    ? `SELECT direction, COUNT(*) AS cnt, ROUND(SUM(duration_s)/60.0, 1) AS total_min,
              ROUND(AVG(duration_s), 1) AS avg_sec
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY direction ORDER BY cnt DESC`
    : '';
  const { data: dirData } = useSfQuery(dirSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const hexSql = airport
    ? `SELECT H3_POINT_TO_CELL_STRING(midpoint_geom, 12) AS h3_cell,
              ROUND(COUNT(DISTINCT flight_key)/${days}) AS flight_count
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
         AND midpoint_geom IS NOT NULL
       GROUP BY 1 HAVING flight_count > 0`
    : '';
  const { data: hexData } = useSfQuery(hexSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const recentSql = airport
    ? `SELECT flight_number AS FLIGHT, airline_code AS AIRLINE, direction AS DIR,
              t_entry AS ENTRY, t_exit AS EXIT, ROUND(duration_s,1) AS DURATION_S,
              ROUND(max_speed_kts,1) AS MAX_SPEED_KTS
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       ORDER BY t_entry DESC LIMIT 100`
    : '';
  const { data: recentData } = useSfQuery(recentSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const runwaySql = airport
    ? `SELECT ST_ASGEOJSON(runway_geog) AS geojson FROM ${db}.PROPERTIES_RUNWAYS`
    : '';
  const { data: runwayRows } = useSfQuery(runwaySql, airport, 'PUBLIC');

  const layers = useMemo(() => {
    const result: any[] = [];
    if (hexData.length) {
      const maxVal = Math.max(...hexData.map((d: any) => Number(d.FLIGHT_COUNT) || 0), 1);
      result.push(new H3HexagonLayer({
        id: 'crossing-hex',
        data: hexData,
        getHexagon: (d: any) => d.H3_CELL,
        getFillColor: (d: any) => {
          const t = Math.min(1, (Number(d.FLIGHT_COUNT) || 0) / maxVal);
          return [Math.round(255 * t), Math.round(165 * (1 - t)), 0, 180];
        },
        getElevation: (d: any) => (Number(d.FLIGHT_COUNT) || 0) / maxVal * 100,
        extruded: true,
        elevationScale: 1,
        pickable: true,
      }));
    }
    if (runwayRows.length) {
      const features = runwayRows
        .filter((r: any) => r.GEOJSON)
        .map((r: any) => ({ type: 'Feature' as const, geometry: JSON.parse(r.GEOJSON), properties: {} }));
      if (features.length) {
        result.push(new GeoJsonLayer({
          id: 'runways',
          data: { type: 'FeatureCollection' as const, features },
          getLineColor: [229, 72, 77, 200],
          getLineWidth: 6,
          lineWidthMinPixels: 3,
        }));
      }
    }
    return result;
  }, [hexData, runwayRows]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: 14, pitch: 40, bearing: 0 }
    : undefined;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-full">
      <div className="page-sidebar-panel">
        <h2>Runway Crossings</h2>
        <p>Safety analytics for runway crossing events.</p>
        <div className="form-group">
          <label>From</label>
          <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
        </div>
        <div className="form-group">
          <label>To</label>
          <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
        </div>
        <div className="metric-grid-vertical" style={{ marginTop: 16 }}>
          <MetricCard label="Avg Daily Flights" value={summary.AVG_FLIGHTS ?? '—'} />
          <MetricCard label="Avg Daily Crossings" value={summary.AVG_CROSSINGS ?? '—'} />
          <MetricCard label="Avg Duration (s)" value={fmtDec(summary.AVG_DURATION)} />
          <MetricCard label="Avg Total (min/day)" value={fmtDec(summary.AVG_TOTAL_MIN)} />
        </div>
        {dirData.length > 0 && (
          <div className="chart-card" style={{ marginTop: 12 }}>
            <h4>By Direction</h4>
            <ResponsiveContainer width="100%" height={dirData.length * 40 + 30}>
              <BarChart data={dirData} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis type="number" tick={{ fontSize: 10 }} />
                <YAxis type="category" dataKey="DIRECTION" tick={{ fontSize: 11 }} width={60} />
                <Tooltip />
                <Bar dataKey="CNT" fill="#29B5E8" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>
      <div className="map-split">
        <MapView layers={layers} initialViewState={viewState}
          getTooltip={({ object }: any) => object && object.H3_CELL && {
            html: `Flights/day: ${object.FLIGHT_COUNT}`,
            style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
          }}
        />
        <div className="chart-bottom" style={{ padding: '12px 24px', maxHeight: 250, overflow: 'auto' }}>
          <h3 style={{ fontSize: 13, marginBottom: 8 }}>Recent Events</h3>
          <DataTable data={recentData} maxRows={100} />
        </div>
      </div>
    </div>
  );
}
