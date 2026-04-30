import { useState, useMemo, useCallback, useRef, useEffect } from 'react';
import { H3HexagonLayer } from '@deck.gl/geo-layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import { fmtNum } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSnowflake, useSfQuery } from '../hooks/useSnowflake';
import LayerPresetSelector from '../shared/LayerPresetSelector';
import { useInfrastructure, type LayerPreset } from '../shared/useInfrastructure';
import VehicleTypeFilter, { useVehicleTypeFilter } from '../shared/VehicleTypeFilter';

type Aggregation = 'day' | 'hour' | '10min';

function slotLabel(slot: number, agg: Aggregation): string {
  if (agg === 'day') return 'Full Day';
  if (agg === 'hour') {
    const h = String(slot).padStart(2, '0');
    const h2 = String((slot + 1) % 24).padStart(2, '0');
    return `${h}:00 – ${h2}:00`;
  }
  const startMin = slot * 10;
  const endMin = startMin + 10;
  const h1 = String(Math.floor(startMin / 60)).padStart(2, '0');
  const m1 = String(startMin % 60).padStart(2, '0');
  const h2 = String(Math.floor(endMin / 60)).padStart(2, '0');
  const m2 = String(endMin % 60).padStart(2, '0');
  return `${h1}:${m1} – ${h2}:${m2}`;
}

function maxSlotForAgg(agg: Aggregation): number {
  if (agg === 'day') return 0;
  if (agg === 'hour') return 23;
  return 143;
}

function yesterday(): string {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().split('T')[0];
}

export default function GroundActivity() {
  const { airport } = useAirport();
  const { query } = useSnowflake();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];

  const [mode, setMode] = useState<'static' | 'replay'>('static');
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);
  const [h3Res, setH3Res] = useState(13);
  const [metric, setMetric] = useState<'flights' | 'points'>('flights');
  const [percentile, setPercentile] = useState(0);
  const [infraPreset, setInfraPreset] = useState<LayerPreset>('airport-ops');
  const [customTypes, setCustomTypes] = useState<Set<string>>(new Set());
  const { layers: infraLayers, availableTypes } = useInfrastructure(infraPreset, customTypes);
  const { selected: vehicleTypes, setSelected: setVehicleTypes, sqlFilter: vehicleFilter } = useVehicleTypeFilter();

  const [replayDate, setReplayDate] = useState(yesterday);
  const [aggregation, setAggregation] = useState<Aggregation>('hour');
  const [slotIndex, setSlotIndex] = useState(0);
  const [replayData, setReplayData] = useState<any[]>([]);
  const [replayLoading, setReplayLoading] = useState(false);
  const loadedKeyRef = useRef('');

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON, AIRPORT_TZID,
              MIN_LON AS BBOX_MIN_LON, MIN_LAT AS BBOX_MIN_LAT,
              MAX_LON AS BBOX_MAX_LON, MAX_LAT AS BBOX_MAX_LAT
       FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;
  const tz = meta?.AIRPORT_TZID || 'UTC';

  const days = Math.max(1, Math.round((new Date(dateTo).getTime() - new Date(dateFrom).getTime()) / 86400000) + 1);

  const hexSql = airport && meta && mode === 'static'
    ? `SELECT H3_POINT_TO_CELL_STRING(LOCATION, ${h3Res}) AS h3_cell,
              ROUND(COUNT(DISTINCT FLIGHT) / ${days}) AS flight_count,
              ROUND(COUNT(*) / ${days}) AS obs_count
       FROM ${db}.ADSB_DATA_LOCAL SAMPLE BERNOULLI (${days > 14 ? 10 : 50})
       WHERE TIMESTAMP >= '${dateFrom}'::TIMESTAMP AND TIMESTAMP < DATEADD('day', 1, '${dateTo}'::DATE)
         AND ST_X(LOCATION) BETWEEN ${meta.BBOX_MIN_LON} AND ${meta.BBOX_MAX_LON}
         AND ST_Y(LOCATION) BETWEEN ${meta.BBOX_MIN_LAT} AND ${meta.BBOX_MAX_LAT}
         AND LOCATION IS NOT NULL
         ${vehicleFilter}
       GROUP BY 1
       HAVING ${metric === 'flights' ? 'flight_count' : 'obs_count'} > 0`
    : '';
  const { data: hexData, loading } = useSfQuery(hexSql, airport, 'PUBLIC', [dateFrom, dateTo, h3Res, metric, mode, vehicleFilter]);

  const loadReplayData = useCallback(async (date: string, agg: Aggregation) => {
    if (!airport || !meta) return;
    const key = `${airport}:${date}:${agg}:${h3Res}`;
    if (loadedKeyRef.current === key) return;
    setReplayLoading(true);
    setReplayData([]);
    setSlotIndex(0);
    try {
      let slotExpr: string;
      if (agg === 'day') {
        slotExpr = '0';
      } else if (agg === 'hour') {
        slotExpr = `EXTRACT(HOUR FROM CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP))`;
      } else {
        slotExpr = `FLOOR(DATEDIFF('minute', DATE_TRUNC('day', CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)), CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)) / 10)`;
      }

      const rows = await query(
        `SELECT H3_POINT_TO_CELL_STRING(LOCATION, ${h3Res}) AS H3_CELL,
                ${slotExpr} AS SLOT,
                COUNT(DISTINCT FLIGHT) AS FLIGHT_COUNT,
                COUNT(*) AS OBS_COUNT
         FROM ${db}.ADSB_DATA_LOCAL
         WHERE TO_DATE(CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)) = '${date}'::DATE
           AND LOCATION IS NOT NULL
           AND ST_X(LOCATION) BETWEEN ${meta.BBOX_MIN_LON} AND ${meta.BBOX_MAX_LON}
           AND ST_Y(LOCATION) BETWEEN ${meta.BBOX_MIN_LAT} AND ${meta.BBOX_MAX_LAT}
           ${vehicleFilter}
         GROUP BY 1, 2`,
        { database: airport, schema: 'PUBLIC' }
      );
      setReplayData(rows || []);
      loadedKeyRef.current = key;
    } finally {
      setReplayLoading(false);
    }
  }, [airport, db, meta, tz, h3Res, query, vehicleFilter]);

  useEffect(() => {
    if (mode === 'replay' && airport && meta) {
      loadReplayData(replayDate, aggregation);
    }
  }, [mode, airport, meta, replayDate, aggregation, loadReplayData]);

  const filteredHex = useMemo(() => {
    if (mode !== 'replay') return [];
    if (aggregation === 'day') return replayData;
    return replayData.filter((d: any) => Number(d.SLOT) === slotIndex);
  }, [mode, replayData, slotIndex, aggregation]);

  const activeDataRaw = mode === 'static' ? hexData : filteredHex;
  const activeLoading = mode === 'static' ? loading : replayLoading;

  const activeData = useMemo(() => {
    if (percentile === 0 || !activeDataRaw.length) return activeDataRaw;
    const key = metric === 'flights' ? 'FLIGHT_COUNT' : 'OBS_COUNT';
    const vals = activeDataRaw.map((d: any) => Number(d[key]) || 0).sort((a: number, b: number) => a - b);
    const threshold = vals[Math.floor(vals.length * percentile / 100)] || 0;
    return activeDataRaw.filter((d: any) => (Number(d[key]) || 0) >= threshold);
  }, [activeDataRaw, percentile, metric]);

  const totalFlights = activeData.reduce((a: number, d: any) => a + (Number(d.FLIGHT_COUNT) || 0), 0);
  const totalObs = activeData.reduce((a: number, d: any) => a + (Number(d.OBS_COUNT) || 0), 0);

  const layers = useMemo(() => {
    const result: any[] = [...infraLayers];
    if (!activeData.length) return result;
    const key = metric === 'flights' ? 'FLIGHT_COUNT' : 'OBS_COUNT';
    const vals = activeData.map((d: any) => Number(d[key]) || 0);
    const maxVal = Math.max(...vals, 1);

    return [
      ...result,
      new H3HexagonLayer({
        id: 'ground-hex',
        data: activeData,
        getHexagon: (d: any) => d.H3_CELL,
        getFillColor: (d: any) => {
          const t = Math.min(1, (Number(d[key]) || 0) / maxVal);
          if (t < 0.5) {
            const s = t * 2;
            return [Math.round(0 + 255 * s), Math.round(137 + (221 - 137) * s), Math.round(123 + (53 - 123) * s), 180];
          }
          const s = (t - 0.5) * 2;
          return [Math.round(255 - 26 * s), Math.round(221 - 168 * s), Math.round(53 - 53 * s), 180];
        },
        getElevation: (d: any) => (Number(d[key]) || 0) / maxVal * 200,
        elevationScale: 1,
        extruded: true,
        pickable: true,
        updateTriggers: {
          getFillColor: [metric, activeData.length, slotIndex],
          getElevation: [metric, activeData.length, slotIndex],
        },
      }),
    ];
  }, [activeData, metric, slotIndex, infraLayers]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: 14, pitch: 45, bearing: 0 }
    : undefined;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-full">
      <div className="page-sidebar-panel">
        <h2>Ground Activity</h2>
        <div style={{ marginBottom: 14 }}>
          <div className="mode-toggle">
            <button className={`mode-toggle-btn ${mode === 'static' ? 'active' : ''}`} onClick={() => setMode('static')}>Static</button>
            <button className={`mode-toggle-btn ${mode === 'replay' ? 'active' : ''}`} onClick={() => setMode('replay')}>Replay</button>
          </div>
        </div>

        {mode === 'static' && (
          <>
            <div className="form-group">
              <label>From</label>
              <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
            </div>
            <div className="form-group">
              <label>To</label>
              <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
            </div>
          </>
        )}

        {mode === 'replay' && (
          <>
            <div className="form-group">
              <label>Date</label>
              <input type="date" className="form-input" value={replayDate}
                onChange={e => { setReplayDate(e.target.value); loadedKeyRef.current = ''; }} />
            </div>
            <div className="form-group">
              <label>Aggregation</label>
              <select className="form-select" value={aggregation}
                onChange={e => { setAggregation(e.target.value as Aggregation); setSlotIndex(0); loadedKeyRef.current = ''; }}>
                <option value="day">Full Day</option>
                <option value="hour">Hourly</option>
                <option value="10min">10 Minutes</option>
              </select>
            </div>
          </>
        )}

        <div className="form-group">
          <label>Hexagon Size</label>
          <select className="form-select" value={h3Res} onChange={e => { setH3Res(Number(e.target.value)); if (mode === 'replay') loadedKeyRef.current = ''; }}>
            <option value={12}>Large (H3 Res 12)</option>
            <option value={13}>Medium (H3 Res 13)</option>
            <option value={14}>Small (H3 Res 14)</option>
          </select>
        </div>
        <div className="form-group">
          <label>Metric</label>
          <select className="form-select" value={metric} onChange={e => setMetric(e.target.value as any)}>
            <option value="flights">{mode === 'static' ? 'Daily Avg Flights' : 'Flights'}</option>
            <option value="points">{mode === 'static' ? 'Daily Avg Points' : 'Observations'}</option>
          </select>
        </div>
        <div className="form-group">
          <label>Percentile Threshold: {percentile}</label>
          <input type="range" min={0} max={99} step={5} value={percentile}
            onChange={e => setPercentile(Number(e.target.value))} style={{ width: '100%' }} />
        </div>
        <LayerPresetSelector preset={infraPreset} onPresetChange={setInfraPreset}
          customTypes={customTypes} onCustomTypesChange={setCustomTypes} availableTypes={availableTypes} />
        <VehicleTypeFilter selected={vehicleTypes} onChange={setVehicleTypes} />

        <div className="metric-grid-vertical" style={{ marginTop: 16 }}>
          <MetricCard label="Hexagon Cells" value={activeLoading ? '...' : fmtNum(activeData.length)} />
          <MetricCard
            label={mode === 'static' ? 'Total Daily Avg Flights' : `Flights${aggregation !== 'day' ? ` (${slotLabel(slotIndex, aggregation)})` : ''}`}
            value={fmtNum(totalFlights)}
          />
          <MetricCard
            label={mode === 'static' ? 'Total Daily Avg Points' : `Observations${aggregation !== 'day' ? ` (${slotLabel(slotIndex, aggregation)})` : ''}`}
            value={fmtNum(totalObs)}
          />
        </div>

        {mode === 'replay' && replayLoading && (
          <p style={{ fontSize: 12, color: 'var(--text-secondary)' }}>Loading ADS-B data...</p>
        )}
        {mode === 'replay' && !replayLoading && replayData.length > 0 && (
          <p style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
            {fmtNum(replayData.length)} cell-slot records loaded
          </p>
        )}
      </div>
      <div style={{ flex: 1, position: 'relative' }}>
        <MapView layers={layers} initialViewState={viewState}
          getTooltip={({ object }: any) => object && {
            html: `Flights: ${object.FLIGHT_COUNT}<br/>Points: ${object.OBS_COUNT}`,
            style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
          }}
        />
        {mode === 'replay' && replayData.length > 0 && aggregation !== 'day' && (
          <div className="playback-bar">
            <span className="playback-time">{slotLabel(slotIndex, aggregation)}</span>
            <input
              type="range"
              min={0}
              max={maxSlotForAgg(aggregation)}
              step={1}
              value={slotIndex}
              onChange={e => setSlotIndex(Number(e.target.value))}
              style={{ flex: 1 }}
            />
            <span className="playback-count">
              {fmtNum(filteredHex.length)} cells &middot; {fmtNum(totalFlights)} flights
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
