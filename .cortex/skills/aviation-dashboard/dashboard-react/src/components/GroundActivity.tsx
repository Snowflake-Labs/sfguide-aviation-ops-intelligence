import { useState, useMemo } from 'react';
import { H3HexagonLayer } from '@deck.gl/geo-layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import { fmtNum } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';

export default function GroundActivity() {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';
  const today = new Date().toISOString().split('T')[0];
  const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().split('T')[0];
  const [dateFrom, setDateFrom] = useState(weekAgo);
  const [dateTo, setDateTo] = useState(today);
  const [h3Res, setH3Res] = useState(13);
  const [metric, setMetric] = useState<'flights' | 'points'>('flights');

  const airportSql = airport
    ? `SELECT LAT, LON, ZOOM, BBOX_MIN_LON, BBOX_MIN_LAT, BBOX_MAX_LON, BBOX_MAX_LAT FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const days = Math.max(1, Math.round((new Date(dateTo).getTime() - new Date(dateFrom).getTime()) / 86400000) + 1);

  const hexSql = airport && meta
    ? `SELECT H3_POINT_TO_CELL_STRING(LOCATION, ${h3Res}) AS h3_cell,
              ROUND(COUNT(DISTINCT FLIGHT) / ${days}) AS flight_count,
              ROUND(COUNT(*) / ${days}) AS obs_count
       FROM ${db}.ADSB_DATA_LOCAL SAMPLE BERNOULLI (${days > 14 ? 10 : 50})
       WHERE TIMESTAMP >= '${dateFrom}'::TIMESTAMP AND TIMESTAMP < DATEADD('day', 1, '${dateTo}'::DATE)
         AND ST_X(LOCATION) BETWEEN ${meta.BBOX_MIN_LON} AND ${meta.BBOX_MAX_LON}
         AND ST_Y(LOCATION) BETWEEN ${meta.BBOX_MIN_LAT} AND ${meta.BBOX_MAX_LAT}
         AND LOCATION IS NOT NULL
       GROUP BY 1
       HAVING ${metric === 'flights' ? 'flight_count' : 'obs_count'} > 0`
    : '';
  const { data: hexData, loading } = useSfQuery(hexSql, airport, 'PUBLIC', [dateFrom, dateTo, h3Res, metric]);

  const totalFlights = hexData.reduce((a, d: any) => a + (Number(d.FLIGHT_COUNT) || 0), 0);
  const totalObs = hexData.reduce((a, d: any) => a + (Number(d.OBS_COUNT) || 0), 0);

  const layers = useMemo(() => {
    if (!hexData.length) return [];
    const key = metric === 'flights' ? 'FLIGHT_COUNT' : 'OBS_COUNT';
    const vals = hexData.map((d: any) => Number(d[key]) || 0);
    const maxVal = Math.max(...vals, 1);

    return [
      new H3HexagonLayer({
        id: 'ground-hex',
        data: hexData,
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
      }),
    ];
  }, [hexData, metric]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: Number(meta.ZOOM || 14), pitch: 45, bearing: 0 }
    : undefined;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-full">
      <div className="page-sidebar-panel">
        <h2>Ground Activity</h2>
        <p>H3 hexagon density of aircraft/vehicle positions.</p>
        <div className="form-group">
          <label>From</label>
          <input type="date" className="form-input" value={dateFrom} onChange={e => setDateFrom(e.target.value)} />
        </div>
        <div className="form-group">
          <label>To</label>
          <input type="date" className="form-input" value={dateTo} onChange={e => setDateTo(e.target.value)} />
        </div>
        <div className="form-group">
          <label>Hexagon Size</label>
          <select className="form-select" value={h3Res} onChange={e => setH3Res(Number(e.target.value))}>
            <option value={12}>Large (H3 Res 12)</option>
            <option value={13}>Medium (H3 Res 13)</option>
            <option value={14}>Small (H3 Res 14)</option>
          </select>
        </div>
        <div className="form-group">
          <label>Metric</label>
          <select className="form-select" value={metric} onChange={e => setMetric(e.target.value as any)}>
            <option value="flights">Daily Avg Flights</option>
            <option value="points">Daily Avg Points</option>
          </select>
        </div>
        <div className="metric-grid-vertical" style={{ marginTop: 16 }}>
          <MetricCard label="Hexagon Cells" value={loading ? '...' : fmtNum(hexData.length)} />
          <MetricCard label="Total Daily Avg Flights" value={fmtNum(totalFlights)} />
          <MetricCard label="Total Daily Avg Points" value={fmtNum(totalObs)} />
        </div>
      </div>
      <MapView layers={layers} initialViewState={viewState}
        getTooltip={({ object }: any) => object && {
          html: `Flights/day: ${object.FLIGHT_COUNT}<br/>Points/day: ${object.OBS_COUNT}`,
          style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
        }}
      />
    </div>
  );
}
