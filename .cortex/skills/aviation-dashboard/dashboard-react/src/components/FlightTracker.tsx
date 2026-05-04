import { useState, useMemo, useCallback } from 'react';
import { ScatterplotLayer, PathLayer } from '@deck.gl/layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import { fmtNum, fmtAltitude, fmtSpeed, fmtTime } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSnowflake, useSfQuery } from '../hooks/useSnowflake';
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, ReferenceLine } from 'recharts';
import { useInfrastructure, type LayerPreset } from '../shared/useInfrastructure';
import LayerPresetSelector from '../shared/LayerPresetSelector';

interface TrackPoint {
  lat: number; lon: number; sec: number;
  alt: number; vel: number; track: number; onGround: boolean;
}

const GROUND_CATEGORIES = new Set([
  'TOWER', 'SERVICE_VEHICLE', 'GROUND_VEHICLE', 'LIGHT_SURFACE_VEHICLE', 'UNKNOWN_SURFACE',
]);

const VEHICLE_TYPE_LABELS: Record<string, string> = {
  HEAVY_AIRCRAFT: 'Heavy (A380, 777)',
  MEDIUM_AIRCRAFT: 'Medium (737, A320)',
  LARGE_AIRLINER: 'Large (A321, 38M)',
  SMALL_COMMUTER: 'Small Commuter',
  LIGHT_AIRCRAFT: 'Light Aircraft',
  HELICOPTER: 'Helicopter',
  HIGH_PERFORMANCE_MILITARY: 'Military',
  ULTRALIGHT_EXPERIMENTAL: 'Ultralight',
  TOWER: 'Tower',
  SERVICE_VEHICLE: 'Service Vehicle',
  GROUND_VEHICLE: 'Ground Vehicle',
  LIGHT_SURFACE_VEHICLE: 'Emergency/Light',
  UNKNOWN_SURFACE: 'Unknown Surface',
  OTHER: 'Other',
};

function secToHMS(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function lerp(a: number, b: number, t: number) { return a + (b - a) * t; }

function interpolateTrackPoint(pts: TrackPoint[], sec: number): TrackPoint | null {
  if (!pts.length) return null;
  if (sec <= pts[0].sec) return { ...pts[0] };
  if (sec >= pts[pts.length - 1].sec) return { ...pts[pts.length - 1] };
  let lo = 0, hi = pts.length - 1;
  while (lo < hi - 1) {
    const mid = (lo + hi) >> 1;
    if (pts[mid].sec <= sec) lo = mid; else hi = mid;
  }
  const a = pts[lo], b = pts[hi];
  const t = b.sec > a.sec ? (sec - a.sec) / (b.sec - a.sec) : 0;
  return {
    lat: lerp(a.lat, b.lat, t),
    lon: lerp(a.lon, b.lon, t),
    sec,
    alt: lerp(a.alt, b.alt, t),
    vel: lerp(a.vel, b.vel, t),
    track: lerp(a.track, b.track, t),
    onGround: t < 0.5 ? a.onGround : b.onGround,
  };
}

function altColor(alt: number, min: number, max: number): [number, number, number] {
  const t = max > min ? Math.max(0, Math.min(1, (alt - min) / (max - min))) : 0;
  if (t < 0.5) {
    const s = t * 2;
    return [Math.round(0 + 255 * s), Math.round(137 + (221 - 137) * s), Math.round(53 - 70 * s)];
  }
  const s = (t - 0.5) * 2;
  return [Math.round(255 - 26 * s), Math.round(221 - 168 * s), Math.round(53 - 53 * s)];
}

function flightLabel(f: any): string {
  const cat = String(f.VEHICLE_CATEGORY || '');
  if (GROUND_CATEGORIES.has(cat)) {
    return `${f.FLIGHT} | ${VEHICLE_TYPE_LABELS[cat] || cat.replace(/_/g, ' ')}`;
  }
  const parts = [f.FLIGHT];
  if (f.AIRLINE) parts.push(f.AIRLINE);
  const od = [f.ORIGIN, f.DEST].filter(Boolean).join('\u2192');
  if (od) parts.push(od);
  return parts.join(' | ');
}

type VehicleGroup = 'all' | 'aircraft' | 'ground';

export default function FlightTracker() {
  const { airport } = useAirport();
  const { query } = useSnowflake();
  const db = airport ? `${airport}.PUBLIC` : '';
  const [infraPreset, setInfraPreset] = useState<LayerPreset>('airport-ops');
  const [customTypes, setCustomTypes] = useState<Set<string>>(new Set());
  const { layers: infraLayers, availableTypes } = useInfrastructure(infraPreset, customTypes);
  const [date, setDate] = useState(() => new Date().toISOString().split('T')[0]);
  const [selectedFlight, setSelectedFlight] = useState<string | null>(null);
  const [trackData, setTrackData] = useState<any[]>([]);
  const [flightMeta, setFlightMeta] = useState<any>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [minTime, setMinTime] = useState(0);
  const [maxTime, setMaxTime] = useState(0);
  const [vehicleGroup, setVehicleGroup] = useState<VehicleGroup>('aircraft');

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON, AIRPORT_TZID FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;
  const tz = meta?.AIRPORT_TZID || 'UTC';

  const flightListSql = airport && date
    ? `SELECT FLIGHT_ID AS FLIGHT, AIRLINE_NAME AS AIRLINE, ORIGIN_AIRPORT AS ORIGIN,
              DESTINATION_AIRPORT AS DEST, POINTS, VEHICLE_CATEGORY
       FROM ${db}.FLIGHT_TRACKER_FLIGHT_LIST
       WHERE SERVICE_DATE = '${date}'::DATE
       QUALIFY ROW_NUMBER() OVER (ORDER BY POINTS DESC, FLIGHT_ID ASC) <= 500`
    : '';
  const { data: flightList, loading: listLoading } = useSfQuery(flightListSql, airport, 'PUBLIC', [date]);

  const filteredFlights = useMemo(() => {
    if (vehicleGroup === 'all') return flightList;
    return flightList.filter((f: any) => {
      const isGround = GROUND_CATEGORIES.has(String(f.VEHICLE_CATEGORY || ''));
      return vehicleGroup === 'ground' ? isGround : !isGround;
    });
  }, [flightList, vehicleGroup]);

  const groupCounts = useMemo(() => {
    let aircraft = 0, ground = 0;
    for (const f of flightList) {
      if (GROUND_CATEGORIES.has(String(f.VEHICLE_CATEGORY || ''))) ground++;
      else aircraft++;
    }
    return { aircraft, ground, all: flightList.length };
  }, [flightList]);

  const loadTrack = useCallback(async (flight: string) => {
    setSelectedFlight(flight);
    const rows = await query(
      `SELECT FLIGHT, TIMESTAMP, ST_Y(LOCATION) AS LAT, ST_X(LOCATION) AS LON,
              ALTITUDE_BARO, TRACK, VELOCITY,
              (ALTITUDE_BARO IS NOT NULL AND ALTITUDE_BARO <= 100 AND COALESCE(VELOCITY, 0) < 50) AS ON_GROUND,
              DATEDIFF('second',
                DATE_TRUNC('day', CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)),
                CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)
              ) AS SEC_OF_DAY
       FROM ${db}.ADSB_DATA_LOCAL
       WHERE FLIGHT = '${flight}'
         AND TO_DATE(CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)) = '${date}'::DATE
         AND LOCATION IS NOT NULL
       ORDER BY TIMESTAMP ASC`,
      { database: airport, schema: 'PUBLIC' }
    );
    const data = rows || [];
    setTrackData(data);

    if (data.length) {
      const secs = data.map((d: any) => Number(d.SEC_OF_DAY) || 0);
      const mn = Math.min(...secs);
      const mx = Math.max(...secs);
      setMinTime(mn);
      setMaxTime(mx);
      setCurrentTime(mn);
    } else {
      setMinTime(0);
      setMaxTime(0);
      setCurrentTime(0);
    }

    const metaR = await query(
      `SELECT s.AIRLINE_IATA, s.AIRLINE_NAME,
              s.DEPARTURE_AIRPORT AS DEP_IATA, s.ARRIVAL_AIRPORT AS ARR_IATA,
              s.DEPARTURE_SCHEDULED AS SCHEDULED_DEPARTURE_UTC,
              s.ARRIVAL_SCHEDULED AS SCHEDULED_ARRIVAL_UTC
       FROM ${db}.FLIGHT_SCHEDULE s
       WHERE (s.FLIGHT_IATA = '${flight}' OR s.FLIGHT_ICAO = '${flight}')
         AND s.FLIGHT_DATE = '${date}'::DATE
       LIMIT 1`,
      { database: airport, schema: 'PUBLIC' }
    );
    setFlightMeta(metaR?.[0] || null);
  }, [airport, db, date, tz, query]);

  const trackPoints = useMemo<TrackPoint[]>(() => {
    return trackData
      .filter((d: any) => d.LAT != null && d.LON != null)
      .map((d: any) => ({
        lat: Number(d.LAT),
        lon: Number(d.LON),
        sec: Number(d.SEC_OF_DAY) || 0,
        alt: Number(d.ALTITUDE_BARO) || 0,
        vel: Number(d.VELOCITY) || 0,
        track: Number(d.TRACK) || 0,
        onGround: d.ON_GROUND === true || d.ON_GROUND === 'true',
      }));
  }, [trackData]);

  const currentPos = useMemo(() => {
    return interpolateTrackPoint(trackPoints, currentTime);
  }, [trackPoints, currentTime]);

  const layers = useMemo(() => {
    const base = [...infraLayers];
    if (!trackPoints.length) return base;
    const alts = trackPoints.map(d => d.alt);
    const minAlt = Math.min(...alts, 0);
    const maxAlt = Math.max(...alts, 1);

    const path = trackPoints.map(d => [d.lon, d.lat]);
    const avgAlt = alts.length ? alts.reduce((a, b) => a + b, 0) / alts.length : 0;
    const color = altColor(avgAlt, minAlt, maxAlt);

    const result: any[] = [
      ...base,
      new PathLayer({
        id: 'flight-path',
        data: [{ path, color }],
        getPath: (d: any) => d.path,
        getColor: (d: any) => [...d.color, 200],
        widthMinPixels: 3,
        pickable: false,
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

    if (currentPos) {
      result.push(
        new ScatterplotLayer({
          id: 'flight-current-pos',
          data: [currentPos],
          getPosition: (d: TrackPoint) => [d.lon, d.lat],
          getFillColor: [41, 181, 232, 230],
          getLineColor: [255, 255, 255, 220],
          getRadius: 120,
          radiusMinPixels: 7,
          radiusMaxPixels: 14,
          stroked: true,
          lineWidthMinPixels: 2,
          pickable: true,
        })
      );
    }

    return result;
  }, [trackPoints, currentPos, infraLayers]);

  const profileData = useMemo(() => {
    return trackData
      .filter(d => d.TIMESTAMP)
      .map(d => ({
        time: fmtTime(d.TIMESTAMP),
        sec: Number(d.SEC_OF_DAY) || 0,
        altitude: Number(d.ALTITUDE_BARO) || 0,
        speed: Number(d.VELOCITY) || 0,
      }));
  }, [trackData]);

  const currentTimeLabel = useMemo(() => {
    const match = profileData.find((d, i) => {
      const next = profileData[i + 1];
      return d.sec <= currentTime && (!next || next.sec > currentTime);
    });
    return match?.time || secToHMS(currentTime);
  }, [profileData, currentTime]);

  const getTooltip = useCallback(({ object, layer }: any) => {
    if (!object) return null;
    const layerId = String(layer?.id || '');
    if (layerId.startsWith('infra-')) {
      const type = object.properties?.type || object.TYPE || '';
      const name = object.properties?.name || object.NAME || '';
      const typeLabel = String(type).replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
      return {
        html: `<b>${typeLabel || 'Infrastructure'}</b>${name ? `<br/>${name}` : ''}`,
        style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
      };
    }
    if (layer?.id !== 'flight-current-pos') return null;
    return {
      html: `<b>${selectedFlight}</b><br/>Alt: ${fmtAltitude(object.alt)}<br/>Speed: ${fmtSpeed(object.vel)}<br/>${object.onGround ? 'On Ground' : 'Airborne'}`,
      style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
    };
  }, [selectedFlight]);

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: 12 }
    : undefined;

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div className="page-full">
      <div className="page-sidebar-panel">
        <h2>Flight Tracker</h2>
        <LayerPresetSelector preset={infraPreset} onPresetChange={setInfraPreset}
          customTypes={customTypes} onCustomTypesChange={setCustomTypes} availableTypes={availableTypes} />
        <div className="form-group">
          <label>Date</label>
          <input type="date" className="form-input" value={date} onChange={e => { setDate(e.target.value); setSelectedFlight(null); setTrackData([]); }} />
        </div>
        <div className="form-group">
          <label>Vehicle Type</label>
          <div className="mode-toggle" style={{ width: '100%' }}>
            {(['aircraft', 'ground', 'all'] as VehicleGroup[]).map(g => (
              <button
                key={g}
                className={`mode-toggle-btn ${vehicleGroup === g ? 'active' : ''}`}
                onClick={() => setVehicleGroup(g)}
                style={{ flex: 1, fontSize: 12 }}
              >
                {g === 'aircraft' ? `Aircraft (${groupCounts.aircraft})` :
                 g === 'ground' ? `Ground (${groupCounts.ground})` :
                 `All (${groupCounts.all})`}
              </button>
            ))}
          </div>
        </div>
        <div className="form-group">
          <label>Flight ({filteredFlights.length})</label>
          <select
            className="form-input"
            value={selectedFlight || ''}
            onChange={e => { const v = e.target.value; if (v) loadTrack(v); else { setSelectedFlight(null); setTrackData([]); } }}
          >
            <option value="">— Select flight —</option>
            {filteredFlights.map((f: any) => (
              <option key={f.FLIGHT} value={f.FLIGHT}>
                {flightLabel(f)}
              </option>
            ))}
          </select>
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
                {trackData.length > 0 && (
                  <ReferenceLine x={currentTimeLabel} stroke="#E53935" strokeWidth={2} strokeDasharray="3 3" />
                )}
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>
      <div className="map-split">
        <MapView layers={layers} initialViewState={viewState} getTooltip={getTooltip}>
          <div className="altitude-legend" style={{ position: 'absolute', bottom: trackData.length > 0 ? 60 : 12, left: 12, right: 12, background: 'rgba(255,255,255,0.92)', backdropFilter: 'blur(4px)', padding: '6px 12px', borderRadius: 6, transition: 'bottom 0.2s' }}>
            <span>Low</span>
            <div className="altitude-bar" />
            <span>High</span>
          </div>
          {trackData.length > 0 && (
            <div className="playback-bar">
              <span className="playback-time">{secToHMS(currentTime)}</span>
              <input
                type="range"
                min={minTime}
                max={maxTime}
                step={1}
                value={currentTime}
                onChange={e => setCurrentTime(Number(e.target.value))}
                style={{ flex: 1 }}
              />
              <span className="playback-count">
                {currentPos ? `${fmtAltitude(currentPos.alt)} | ${fmtSpeed(currentPos.vel)}` : ''}
              </span>
            </div>
          )}
        </MapView>
      </div>
    </div>
  );
}
