import { useState, useMemo, useCallback } from 'react';
import { ScatterplotLayer, PathLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum, fmtAltitude, fmtSpeed } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSnowflake, useSfQuery } from '../hooks/useSnowflake';
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';

function altColor(alt: number, min: number, max: number): [number, number, number] {
  const t = max > min ? Math.max(0, Math.min(1, (alt - min) / (max - min))) : 0;
  if (t < 0.5) {
    const s = t * 2;
    return [Math.round(0 + 255 * s), Math.round(137 + (221 - 137) * s), Math.round(123 + (53 - 123) * s)];
  }
  const s = (t - 0.5) * 2;
  return [Math.round(255 - 26 * s), Math.round(221 - 168 * s), Math.round(53 - 53 * s)];
}

export default function FlightTracker() {
  const { airport } = useAirport();
  const { query } = useSnowflake();
  const db = airport ? `${airport}.PUBLIC` : '';
  const [date, setDate] = useState(() => new Date().toISOString().split('T')[0]);
  const [selectedFlight, setSelectedFlight] = useState<string | null>(null);
  const [trackData, setTrackData] = useState<any[]>([]);
  const [flightMeta, setFlightMeta] = useState<any>(null);

  const airportSql = airport
    ? `SELECT LAT, LON, ZOOM FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;

  const flightListSql = airport && date
    ? `SELECT flight_id AS FLIGHT, airline_name AS AIRLINE, origin_airport AS ORIGIN,
              destination_airport AS DEST, points AS POINTS, VEHICLE_CATEGORY
       FROM ${db}.FLIGHT_TRACKER_FLIGHT_LIST
       WHERE service_date = '${date}'::DATE
       QUALIFY ROW_NUMBER() OVER (ORDER BY points DESC, flight_id ASC) <= 300`
    : '';
  const { data: flightList, loading: listLoading } = useSfQuery(flightListSql, airport, 'PUBLIC', [date]);

  const loadTrack = useCallback(async (flight: string) => {
    setSelectedFlight(flight);
    const rows = await query(
      `SELECT FLIGHT, TIMESTAMP, ST_Y(LOCATION) AS LAT, ST_X(LOCATION) AS LON,
              ALTITUDE_BARO, TRACK, VELOCITY
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE FLIGHT = '${flight}'
         AND TO_DATE(CONVERT_TIMEZONE('UTC', (SELECT AIRPORT_TZID FROM ${db}.PROPERTIES_AIRPORT LIMIT 1), TIMESTAMP)) = '${date}'::DATE
         AND LOCATION IS NOT NULL
       ORDER BY TIMESTAMP ASC`,
      { database: airport, schema: 'PUBLIC' }
    );
    setTrackData(rows || []);

    const metaR = await query(
      `SELECT s.AIRLINE_IATA, s.AIRLINE_NAME, s.DEP_IATA, s.ARR_IATA,
              s.SCHEDULED_DEPARTURE_UTC, s.SCHEDULED_ARRIVAL_UTC
       FROM ${db}.FLIGHT_SCHEDULE s
       WHERE (s.FLIGHT_IATA = '${flight}' OR s.FLIGHT_ICAO = '${flight}')
         AND s.FLIGHT_DATE = '${date}'::DATE
       LIMIT 1`,
      { database: airport, schema: 'PUBLIC' }
    );
    setFlightMeta(metaR?.[0] || null);
  }, [airport, db, date, query]);

  const layers = useMemo(() => {
    if (!trackData.length) return [];
    const alts = trackData.map(d => Number(d.ALTITUDE_BARO || 0)).filter(Number.isFinite);
    const minAlt = Math.min(...alts, 0);
    const maxAlt = Math.max(...alts, 1);

    const path = trackData
      .filter(d => d.LAT != null && d.LON != null)
      .map(d => [Number(d.LON), Number(d.LAT)]);

    const avgAlt = alts.length ? alts.reduce((a, b) => a + b, 0) / alts.length : 0;
    const color = altColor(avgAlt, minAlt, maxAlt);

    return [
      new PathLayer({
        id: 'flight-path',
        data: [{ path, color }],
        getPath: (d: any) => d.path,
        getColor: (d: any) => [...d.color, 200],
        widthMinPixels: 3,
        pickable: true,
      }),
      new ScatterplotLayer({
        id: 'flight-endpoints',
        data: [
          { pos: path[0], color: [13, 176, 72, 255] },
          { pos: path[path.length - 1], color: [229, 72, 77, 255] },
        ].filter(d => d.pos),
        getPosition: (d: any) => d.pos,
        getFillColor: (d: any) => d.color,
        getRadius: 80,
        radiusMinPixels: 5,
      }),
    ];
  }, [trackData]);

  const profileData = useMemo(() => {
    return trackData
      .filter(d => d.TIMESTAMP)
      .map(d => ({
        time: String(d.TIMESTAMP).slice(11, 19),
        altitude: Number(d.ALTITUDE_BARO) || 0,
        speed: Number(d.VELOCITY) || 0,
      }));
  }, [trackData]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: Number(meta.ZOOM || 12) }
    : undefined;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-full">
      <div className="page-sidebar-panel">
        <h2>Flight Tracker</h2>
        <div className="form-group">
          <label>Date</label>
          <input type="date" className="form-input" value={date} onChange={e => setDate(e.target.value)} />
        </div>
        {selectedFlight && flightMeta && (
          <div className="flight-info-grid">
            <div className="info-label">Flight</div><div className="info-value">{selectedFlight}</div>
            <div className="info-label">Airline</div><div className="info-value">{flightMeta.AIRLINE_NAME || '—'}</div>
            <div className="info-label">Route</div><div className="info-value">{flightMeta.DEP_IATA || '?'} → {flightMeta.ARR_IATA || '?'}</div>
          </div>
        )}
        {selectedFlight && (
          <div className="metric-grid-vertical">
            <MetricCard label="Track Points" value={fmtNum(trackData.length)} />
            <MetricCard label="Max Altitude" value={fmtAltitude(Math.max(...trackData.map(d => Number(d.ALTITUDE_BARO) || 0)))} />
            <MetricCard label="Max Speed" value={fmtSpeed(Math.max(...trackData.map(d => Number(d.VELOCITY) || 0)))} />
          </div>
        )}
        {selectedFlight && profileData.length > 0 && (
          <div className="chart-card" style={{ marginTop: 12 }}>
            <h4>Altitude Profile</h4>
            <ResponsiveContainer width="100%" height={120}>
              <LineChart data={profileData}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="time" tick={{ fontSize: 10 }} interval="preserveStartEnd" />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip />
                <Line type="monotone" dataKey="altitude" stroke="#29B5E8" dot={false} strokeWidth={1.5} />
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}
        <div style={{ marginTop: 16 }}>
          <h3 style={{ fontSize: 13, marginBottom: 8 }}>Flights ({flightList.length})</h3>
          {listLoading ? <div className="loading-text">Loading...</div> : (
            <div style={{ maxHeight: 300, overflowY: 'auto' }}>
              {flightList.map((f: any) => (
                <button
                  key={f.FLIGHT}
                  className={`sidebar-link ${selectedFlight === f.FLIGHT ? 'active' : ''}`}
                  onClick={() => loadTrack(f.FLIGHT)}
                >
                  <span style={{ fontWeight: 500 }}>{f.FLIGHT}</span>
                  <span style={{ fontSize: 11, color: 'var(--text-secondary)', marginLeft: 'auto' }}>{f.POINTS} pts</span>
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
      <div className="map-split">
        <MapView layers={layers} initialViewState={viewState}>
          <div className="altitude-legend" style={{ position: 'absolute', bottom: 12, left: 12, right: 12, background: 'rgba(255,255,255,0.92)', backdropFilter: 'blur(4px)', padding: '6px 12px', borderRadius: 6 }}>
            <span>Low</span>
            <div className="altitude-bar" />
            <span>High</span>
          </div>
        </MapView>
      </div>
    </div>
  );
}
