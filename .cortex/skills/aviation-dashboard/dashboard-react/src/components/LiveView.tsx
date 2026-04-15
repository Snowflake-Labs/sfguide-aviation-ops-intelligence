import { useState, useMemo } from 'react';
import { ScatterplotLayer, PathLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSfQuery } from '../hooks/useSnowflake';

function altitudeColor(alt: number, min: number, max: number): [number, number, number, number] {
  const t = max > min ? (alt - min) / (max - min) : 0;
  if (t < 0.5) {
    const s = t * 2;
    return [Math.round(0 + 255 * s), Math.round(137 + (221 - 137) * s), Math.round(123 + (53 - 123) * s), 200];
  }
  const s = (t - 0.5) * 2;
  return [Math.round(255 - 26 * s), Math.round(221 - 168 * s), Math.round(53 - 53 * s), 200];
}

export default function LiveView() {
  const { airport } = useAirport();
  const [lookback] = useState(60);
  const db = airport ? `${airport}.PUBLIC` : '';

  const airportSql = airport
    ? `SELECT LAT, LON, ZOOM, AIRPORT_TZID FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const liveSql = airport
    ? `WITH now_utc AS (SELECT TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())) AS ts)
SELECT h.FLIGHT, h.REGISTRATION, h.AIRCRAFT_DESC, h.AIRLINE_NAME,
       h.DIRECTION, h.DEPARTURE_AIRPORT, h.ARRIVAL_AIRPORT,
       h.NEAREST_GATE, h.PLANNED_GATE, h.ACTUAL_GATE, h.SCHEDULE_STATUS,
       h.LAT, h.LON, h.ALTITUDE_BARO, h.VELOCITY, h.TRACK, h.LAST_SEEN,
       h.DEPARTURE_SCHEDULED, h.ARRIVAL_SCHEDULED
FROM ${db}.HELPER_LANDING_LIVE_TIMETABLE h
CROSS JOIN now_utc
WHERE h.LAST_SEEN >= DATEADD('minute', -${lookback}, now_utc.ts)
ORDER BY h.LAST_SEEN DESC`
    : '';
  const { data: flights, loading } = useSfQuery(liveSql, airport, 'PUBLIC');

  const arrivals = flights.filter((f: any) => String(f.DIRECTION).toLowerCase() === 'arrival').length;
  const departures = flights.filter((f: any) => String(f.DIRECTION).toLowerCase() === 'departure').length;
  const withGate = flights.filter((f: any) => f.ACTUAL_GATE).length;

  const layers = useMemo(() => {
    if (!flights.length) return [];
    const pts = flights.filter((f: any) => f.LAT != null && f.LON != null);
    return [
      new ScatterplotLayer({
        id: 'live-aircraft',
        data: pts,
        getPosition: (d: any) => [Number(d.LON), Number(d.LAT)],
        getFillColor: (d: any) => {
          const dir = String(d.DIRECTION || '').toLowerCase();
          if (dir === 'arrival') return [66, 133, 244, 200];
          if (dir === 'departure') return [219, 68, 55, 200];
          return [120, 120, 120, 180];
        },
        getRadius: 60,
        radiusMinPixels: 3,
        radiusMaxPixels: 10,
        pickable: true,
      }),
    ];
  }, [flights]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: Number(meta.ZOOM || 12), pitch: 0, bearing: 0 }
    : undefined;

  const timetableCols = [
    'FLIGHT', 'AIRLINE_NAME', 'DIRECTION', 'DEPARTURE_AIRPORT', 'ARRIVAL_AIRPORT',
    'NEAREST_GATE', 'PLANNED_GATE', 'ACTUAL_GATE', 'SCHEDULE_STATUS', 'LAST_SEEN',
  ];

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ padding: '16px 24px 0', flexShrink: 0 }}>
        <div className="metric-grid">
          <MetricCard label="Live Aircraft" value={loading ? '...' : fmtNum(flights.length)} />
          <MetricCard label="Arrivals" value={fmtNum(arrivals)} />
          <MetricCard label="Departures" value={fmtNum(departures)} />
          <MetricCard label="With Gate" value={fmtNum(withGate)} />
        </div>
      </div>
      <div style={{ flex: 1, position: 'relative', minHeight: 400 }}>
        <MapView layers={layers} initialViewState={viewState}
          getTooltip={({ object }: any) => object && {
            html: `<b>${object.FLIGHT}</b><br/>${object.AIRLINE_NAME || ''}<br/>Alt: ${object.ALTITUDE_BARO ?? '—'} ft`,
            style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
          }}
        >
          <div className="map-legend">
            <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#4285F4' }} /> Arrival</div>
            <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#DB4437' }} /> Departure</div>
            <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#787878' }} /> Unknown</div>
          </div>
        </MapView>
      </div>
      <div style={{ padding: '16px 24px', maxHeight: 300, overflow: 'auto', borderTop: '1px solid var(--border)' }}>
        <h3 style={{ fontSize: 14, marginBottom: 8 }}>Live Timetable</h3>
        <DataTable data={flights} columns={timetableCols} maxRows={200} />
      </div>
    </div>
  );
}
