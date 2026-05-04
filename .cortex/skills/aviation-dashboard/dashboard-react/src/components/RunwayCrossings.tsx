import { useState, useMemo } from 'react';
import { H3HexagonLayer } from '@deck.gl/geo-layers';
import { GeoJsonLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import HeatmapGrid, { DOW_LABELS, HOUR_LABELS } from '../shared/HeatmapGrid';
import { fmtNum, fmtDec } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';
import LayerPresetSelector from '../shared/LayerPresetSelector';
import { useInfrastructure, type LayerPreset } from '../shared/useInfrastructure';
import VehicleTypeFilter, { useVehicleTypeFilter } from '../shared/VehicleTypeFilter';
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';

export default function RunwayCrossings() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);
  const [dirFilter, setDirFilter] = useState<Set<string>>(new Set());
  const [infraPreset, setInfraPreset] = useState<LayerPreset>('airport-ops');
  const [customTypes, setCustomTypes] = useState<Set<string>>(new Set());
  const { layers: infraLayers, availableTypes } = useInfrastructure(infraPreset, customTypes);
  const { selected: vehicleTypes, setSelected: setVehicleTypes, sqlFilter: vehicleFilter } = useVehicleTypeFilter();

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const days = Math.max(1, Math.round((new Date(dateTo).getTime() - new Date(dateFrom).getTime()) / 86400000) + 1);
  const dirClause = dirFilter.size > 0
    ? `AND direction IN (${Array.from(dirFilter).map(d => `'${d}'`).join(',')})`
    : '';

  const summarySql = airport
    ? `SELECT ROUND(COUNT(DISTINCT flight_key)/${days}) AS avg_flights,
              ROUND(COUNT(*)/${days}) AS avg_crossings,
              ROUND(AVG(duration_s), 1) AS avg_duration,
              ROUND(SUM(duration_s)/60.0/${days}, 1) AS avg_total_min
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${dirClause}`
    : '';
  const { data: summaryRows } = useSfQuery(summarySql, airport, 'PUBLIC', [dateFrom, dateTo, dirClause]);
  const summary = summaryRows[0] as any || {};

  const dirSql = airport
    ? `SELECT direction AS DIRECTION, COUNT(*) AS CNT, ROUND(SUM(duration_s)/60.0, 1) AS TOTAL_MIN,
              ROUND(AVG(duration_s), 1) AS AVG_SEC
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
       GROUP BY direction ORDER BY CNT DESC`
    : '';
  const { data: dirData } = useSfQuery(dirSql, airport, 'PUBLIC', [dateFrom, dateTo]);

  const hexSql = airport
    ? `SELECT H3_POINT_TO_CELL_STRING(midpoint_geom, 12) AS h3_cell,
              ROUND(COUNT(DISTINCT flight_key)/${days}) AS flight_count
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE
         AND midpoint_geom IS NOT NULL ${dirClause}
       GROUP BY 1 HAVING flight_count > 0`
    : '';
  const { data: hexData } = useSfQuery(hexSql, airport, 'PUBLIC', [dateFrom, dateTo, dirClause]);

  const heatmapSql = airport
    ? `SELECT DAYOFWEEK(service_date) AS DOW, EXTRACT(HOUR FROM t_entry) AS HR, COUNT(*) AS CNT
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${dirClause}
       GROUP BY 1, 2`
    : '';
  const { data: heatmapRaw } = useSfQuery(heatmapSql, airport, 'PUBLIC', [dateFrom, dateTo, dirClause]);
  const heatmapData = useMemo(() =>
    heatmapRaw.map((d: any) => ({ row: DOW_LABELS[Number(d.DOW)], col: String(Number(d.HR)), value: Number(d.CNT) || 0 })),
    [heatmapRaw]);

  const topAirlinesSql = airport
    ? `SELECT airline_code AS AIRLINE, COUNT(*) AS CNT, ROUND(SUM(duration_s)/60.0, 1) AS TOTAL_MIN
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${dirClause}
         AND airline_code IS NOT NULL AND airline_code != ''
       GROUP BY 1 ORDER BY CNT DESC LIMIT 10`
    : '';
  const { data: topAirlines } = useSfQuery(topAirlinesSql, airport, 'PUBLIC', [dateFrom, dateTo, dirClause]);

  const recentSql = airport
    ? `SELECT flight_number AS FLIGHT, airline_code AS AIRLINE, direction AS DIR,
              t_entry AS ENTRY, t_exit AS EXIT, ROUND(duration_s,1) AS DURATION_S,
              ROUND(max_speed_kts,1) AS MAX_SPEED_KTS
       FROM ${db}.RUNWAY_CROSSINGS_DETAILED
       WHERE service_date BETWEEN '${dateFrom}'::DATE AND '${dateTo}'::DATE ${dirClause}
       ORDER BY t_entry DESC LIMIT 100`
    : '';
  const { data: recentData } = useSfQuery(recentSql, airport, 'PUBLIC', [dateFrom, dateTo, dirClause]);

  const runwaySql = airport
    ? `SELECT ST_ASGEOJSON(runway_geog) AS geojson FROM ${db}.PROPERTIES_RUNWAYS`
    : '';
  const { data: runwayRows } = useSfQuery(runwaySql, airport, 'PUBLIC');

  const layers = useMemo(() => {
    const result: any[] = [...infraLayers];
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
  }, [hexData, runwayRows, infraLayers]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: 14, pitch: 40, bearing: 0 }
    : undefined;

  const toggleDir = (d: string) => {
    const next = new Set(dirFilter);
    if (next.has(d)) next.delete(d);
    else next.add(d);
    setDirFilter(next);
  };

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
        {dirData.length > 0 && (
          <div className="form-group">
            <label>Direction Filter</label>
            <div style={{ fontSize: 11 }}>
              {dirData.map((d: any) => (
                <label key={d.DIRECTION} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0', cursor: 'pointer' }}>
                  <input type="checkbox" checked={dirFilter.size === 0 || dirFilter.has(d.DIRECTION)}
                    onChange={() => toggleDir(d.DIRECTION)} />
                  {d.DIRECTION}
                </label>
              ))}
            </div>
          </div>
        )}
        <LayerPresetSelector preset={infraPreset} onPresetChange={setInfraPreset}
          customTypes={customTypes} onCustomTypesChange={setCustomTypes} availableTypes={availableTypes} />
        <VehicleTypeFilter selected={vehicleTypes} onChange={setVehicleTypes} />
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
        <div className="chart-bottom" style={{ padding: '12px 24px', maxHeight: 400, overflow: 'auto' }}>
          {heatmapData.length > 0 && (
            <div style={{ marginBottom: 16 }}>
              <HeatmapGrid data={heatmapData} rowLabels={DOW_LABELS} colLabels={HOUR_LABELS} title="Crossings by Day & Hour" />
            </div>
          )}
          {topAirlines.length > 0 && (
            <div className="chart-card" style={{ marginBottom: 12 }}>
              <h4 style={{ fontSize: 12 }}>Top Airlines by Crossings</h4>
              <ResponsiveContainer width="100%" height={Math.min(topAirlines.length * 28 + 30, 200)}>
                <BarChart data={topAirlines} layout="vertical">
                  <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                  <XAxis type="number" tick={{ fontSize: 9 }} />
                  <YAxis type="category" dataKey="AIRLINE" tick={{ fontSize: 10 }} width={40} />
                  <Tooltip />
                  <Bar dataKey="CNT" fill="#E5A100" radius={[0, 4, 4, 0]} name="Crossings" />
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
          <h3 style={{ fontSize: 13, marginBottom: 8 }}>Recent Events</h3>
          <DataTable data={recentData} maxRows={100} />
        </div>
      </div>
    </div>
  );
}
