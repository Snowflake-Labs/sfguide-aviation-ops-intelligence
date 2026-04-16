import { useState, useMemo, useCallback, useRef, useEffect } from 'react';
import { ScatterplotLayer } from '@deck.gl/layers';
import { TripsLayer } from '@deck.gl/geo-layers';
import MapView from '../shared/MapView';
import MetricCard from '../shared/MetricCard';
import DataTable from '../shared/DataTable';
import { fmtNum, fmtAltitude, fmtSpeed } from '../shared/format';
import { useAirport } from '../hooks/useAirport';
import { useSnowflake, useSfQuery } from '../hooks/useSnowflake';

interface FlightTrail {
  flight: string;
  path: [number, number, number][];
  timestamps: number[];
  points: { lat: number; lon: number; sec: number; alt: number; vel: number; onGround: boolean; track: number }[];
}

interface CurrentPos {
  flight: string;
  lon: number;
  lat: number;
  alt: number;
  vel: number;
  onGround: boolean;
  track: number;
}

function secToHMS(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function lerp(a: number, b: number, t: number) { return a + (b - a) * t; }

function interpolatePosition(pts: FlightTrail['points'], sec: number): CurrentPos | null {
  if (!pts.length) return null;
  if (sec <= pts[0].sec) {
    const p = pts[0];
    return { flight: '', lon: p.lon, lat: p.lat, alt: p.alt, vel: p.vel, onGround: p.onGround, track: p.track };
  }
  if (sec >= pts[pts.length - 1].sec) {
    const p = pts[pts.length - 1];
    return { flight: '', lon: p.lon, lat: p.lat, alt: p.alt, vel: p.vel, onGround: p.onGround, track: p.track };
  }
  let lo = 0, hi = pts.length - 1;
  while (lo < hi - 1) {
    const mid = (lo + hi) >> 1;
    if (pts[mid].sec <= sec) lo = mid; else hi = mid;
  }
  const a = pts[lo], b = pts[hi];
  const t = b.sec > a.sec ? (sec - a.sec) / (b.sec - a.sec) : 0;
  return {
    flight: '',
    lon: lerp(a.lon, b.lon, t),
    lat: lerp(a.lat, b.lat, t),
    alt: lerp(a.alt, b.alt, t),
    vel: lerp(a.vel, b.vel, t),
    onGround: t < 0.5 ? a.onGround : b.onGround,
    track: lerp(a.track, b.track, t),
  };
}

function yesterday(): string {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().split('T')[0];
}

export default function LiveView() {
  const { airport } = useAirport();
  const { query } = useSnowflake();
  const [mode, setMode] = useState<'live' | 'replay'>('live');
  const [lookback] = useState(60);
  const db = airport ? `${airport}.PUBLIC` : '';

  const [replayDate, setReplayDate] = useState(yesterday);
  const [trails, setTrails] = useState<FlightTrail[]>([]);
  const [replayLoading, setReplayLoading] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [maxTime, setMaxTime] = useState(86400);
  const loadedDateRef = useRef('');

  const airportSql = airport
    ? `SELECT CENTER_LAT AS LAT, CENTER_LON AS LON, AIRPORT_TZID FROM ${db}.PROPERTIES_AIRPORT LIMIT 1`
    : '';
  const { data: metaRows } = useSfQuery(airportSql, airport, 'PUBLIC');
  const meta = metaRows[0] as any;
  const tz = meta?.AIRPORT_TZID || 'UTC';

  const liveSql = airport && mode === 'live'
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
  const { data: flights, loading: liveLoading } = useSfQuery(liveSql, airport, 'PUBLIC');

  const loadReplayData = useCallback(async (date: string) => {
    if (!airport || !date) return;
    if (loadedDateRef.current === `${airport}:${date}`) return;
    setReplayLoading(true);
    setTrails([]);
    setCurrentTime(0);
    try {
      const rows = await query(
        `SELECT FLIGHT, IFF(COALESCE(ALTITUDE_BARO, 0) <= 100, TRUE, FALSE) AS ON_GROUND,
                ST_Y(LOCATION) AS LAT, ST_X(LOCATION) AS LON,
                ALTITUDE_BARO, VELOCITY, TRACK,
                DATEDIFF('second',
                  DATE_TRUNC('day', CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)),
                  CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)
                ) AS SEC_OF_DAY
         FROM ${db}.ADSB_DATA_LOCAL
         WHERE TO_DATE(CONVERT_TIMEZONE('UTC', '${tz}', TIMESTAMP)) = '${date}'::DATE
           AND LOCATION IS NOT NULL
         ORDER BY FLIGHT, TIMESTAMP ASC`,
        { database: airport, schema: 'PUBLIC' }
      );
      if (!rows || !rows.length) {
        setTrails([]);
        setMaxTime(86400);
        loadedDateRef.current = `${airport}:${date}`;
        return;
      }
      const byFlight = new Map<string, FlightTrail>();
      let globalMax = 0;
      for (const r of rows) {
        const flt = String(r.FLIGHT || 'UNKNOWN');
        const sec = Number(r.SEC_OF_DAY) || 0;
        const pt = {
          lat: Number(r.LAT), lon: Number(r.LON), sec,
          alt: Number(r.ALTITUDE_BARO) || 0,
          vel: Number(r.VELOCITY) || 0,
          onGround: r.ON_GROUND === true || r.ON_GROUND === 'true',
          track: Number(r.TRACK) || 0,
        };
        if (sec > globalMax) globalMax = sec;
        let trail = byFlight.get(flt);
        if (!trail) {
          trail = { flight: flt, path: [], timestamps: [], points: [] };
          byFlight.set(flt, trail);
        }
        trail.points.push(pt);
        trail.path.push([pt.lon, pt.lat, sec]);
        trail.timestamps.push(sec);
      }
      setTrails(Array.from(byFlight.values()));
      setMaxTime(Math.min(globalMax + 60, 86400));
      loadedDateRef.current = `${airport}:${date}`;
    } finally {
      setReplayLoading(false);
    }
  }, [airport, db, tz, query]);

  useEffect(() => {
    if (mode === 'replay' && airport && replayDate) {
      loadReplayData(replayDate);
    }
  }, [mode, airport, replayDate, loadReplayData]);

  const visiblePositions = useMemo(() => {
    if (mode !== 'replay' || !trails.length) return [];
    const window = 300;
    const result: CurrentPos[] = [];
    for (const trail of trails) {
      const pts = trail.points;
      if (!pts.length) continue;
      if (currentTime < pts[0].sec - window || currentTime > pts[pts.length - 1].sec + window) continue;
      const pos = interpolatePosition(pts, currentTime);
      if (pos) {
        pos.flight = trail.flight;
        result.push(pos);
      }
    }
    return result;
  }, [mode, trails, currentTime]);

  const replayStats = useMemo(() => {
    const total = new Set(trails.map(t => t.flight)).size;
    const visible = visiblePositions.length;
    const airborne = visiblePositions.filter(p => !p.onGround).length;
    const ground = visiblePositions.filter(p => p.onGround).length;
    return { total, visible, airborne, ground };
  }, [trails, visiblePositions]);

  const replayLayers = useMemo(() => {
    if (mode !== 'replay' || !trails.length) return [];
    return [
      new TripsLayer({
        id: 'replay-trails',
        data: trails,
        getPath: (d: FlightTrail) => d.path,
        getTimestamps: (d: FlightTrail) => d.timestamps,
        getColor: (d: FlightTrail) => {
          const lastGround = d.points[d.points.length - 1]?.onGround;
          return lastGround ? [255, 180, 50, 180] : [41, 181, 232, 180];
        },
        currentTime,
        trailLength: 300,
        widthMinPixels: 2,
        capRounded: true,
        jointRounded: true,
      }),
      new ScatterplotLayer<CurrentPos>({
        id: 'replay-positions',
        data: visiblePositions,
        getPosition: (d) => [d.lon, d.lat],
        getFillColor: (d) => d.onGround ? [255, 180, 50, 220] : [41, 181, 232, 220],
        getLineColor: [255, 255, 255, 200],
        getRadius: 50,
        radiusMinPixels: 4,
        radiusMaxPixels: 12,
        stroked: true,
        lineWidthMinPixels: 1,
        pickable: true,
      }),
    ];
  }, [mode, trails, currentTime, visiblePositions]);

  const liveLayers = useMemo(() => {
    if (mode !== 'live' || !flights.length) return [];
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
  }, [mode, flights]);

  const layers = mode === 'live' ? liveLayers : replayLayers;
  const loading = mode === 'live' ? liveLoading : replayLoading;

  const arrivals = flights.filter((f: any) => String(f.DIRECTION).toLowerCase() === 'arrival').length;
  const departures = flights.filter((f: any) => String(f.DIRECTION).toLowerCase() === 'departure').length;
  const withGate = flights.filter((f: any) => f.ACTUAL_GATE).length;

  const viewState = meta
    ? { longitude: Number(meta.LON), latitude: Number(meta.LAT), zoom: 12, pitch: 0, bearing: 0 }
    : undefined;

  const timetableCols = [
    'FLIGHT', 'AIRLINE_NAME', 'DIRECTION', 'DEPARTURE_AIRPORT', 'ARRIVAL_AIRPORT',
    'NEAREST_GATE', 'PLANNED_GATE', 'ACTUAL_GATE', 'SCHEDULE_STATUS', 'LAST_SEEN',
  ];

  const replayTableData = useMemo(() => {
    return visiblePositions.map(p => ({
      FLIGHT: p.flight,
      ALTITUDE: fmtAltitude(p.alt),
      SPEED: fmtSpeed(p.vel),
      STATUS: p.onGround ? 'Ground' : 'Airborne',
    }));
  }, [visiblePositions]);

  const getTooltip = useCallback(({ object }: any) => {
    if (!object) return null;
    if (mode === 'live') {
      return {
        html: `<b>${object.FLIGHT}</b><br/>${object.AIRLINE_NAME || ''}<br/>Alt: ${object.ALTITUDE_BARO ?? '—'} ft`,
        style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
      };
    }
    return {
      html: `<b>${object.flight}</b><br/>Alt: ${fmtAltitude(object.alt)}<br/>Speed: ${fmtSpeed(object.vel)}<br/>${object.onGround ? 'On Ground' : 'Airborne'}`,
      style: { backgroundColor: '#24323D', color: '#fff', fontSize: '12px', padding: '6px 10px', borderRadius: '6px' },
    };
  }, [mode]);

  if (!airport) return <div className="page-dashboard"><p className="empty-state">Select an airport to begin.</p></div>;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ padding: '16px 24px 0', flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
          <div className="mode-toggle">
            <button className={`mode-toggle-btn ${mode === 'live' ? 'active' : ''}`} onClick={() => setMode('live')}>Live</button>
            <button className={`mode-toggle-btn ${mode === 'replay' ? 'active' : ''}`} onClick={() => setMode('replay')}>Replay</button>
          </div>
          {mode === 'replay' && (
            <input
              type="date"
              className="form-input"
              style={{ width: 160 }}
              value={replayDate}
              onChange={e => { setReplayDate(e.target.value); loadedDateRef.current = ''; }}
            />
          )}
          {mode === 'replay' && replayLoading && (
            <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>Loading ADS-B data...</span>
          )}
          {mode === 'replay' && !replayLoading && trails.length > 0 && (
            <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
              {fmtNum(trails.length)} flights &middot; {fmtNum(trails.reduce((s, t) => s + t.points.length, 0))} points
            </span>
          )}
        </div>
        <div className="metric-grid">
          {mode === 'live' ? (
            <>
              <MetricCard label="Live Aircraft" value={loading ? '...' : fmtNum(flights.length)} />
              <MetricCard label="Arrivals" value={fmtNum(arrivals)} />
              <MetricCard label="Departures" value={fmtNum(departures)} />
              <MetricCard label="With Gate" value={fmtNum(withGate)} />
            </>
          ) : (
            <>
              <MetricCard label="Visible Aircraft" value={fmtNum(replayStats.visible)} />
              <MetricCard label="Airborne" value={fmtNum(replayStats.airborne)} />
              <MetricCard label="On Ground" value={fmtNum(replayStats.ground)} />
              <MetricCard label="Total Flights" value={fmtNum(replayStats.total)} />
            </>
          )}
        </div>
      </div>
      <div style={{ flex: 1, position: 'relative', minHeight: 400 }}>
        <MapView layers={layers} initialViewState={viewState} getTooltip={getTooltip}>
          {mode === 'live' && (
            <div className="map-legend">
              <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#4285F4' }} /> Arrival</div>
              <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#DB4437' }} /> Departure</div>
              <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#787878' }} /> Unknown</div>
            </div>
          )}
          {mode === 'replay' && (
            <div className="map-legend">
              <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#29B5E8' }} /> Airborne</div>
              <div className="map-legend-item"><div className="map-legend-dot" style={{ background: '#FFB432' }} /> Ground</div>
            </div>
          )}
        </MapView>
        {mode === 'replay' && trails.length > 0 && (
          <div className="playback-bar">
            <span className="playback-time">{secToHMS(currentTime)}</span>
            <input
              type="range"
              min={0}
              max={maxTime}
              step={1}
              value={currentTime}
              onChange={e => setCurrentTime(Number(e.target.value))}
              style={{ flex: 1 }}
            />
            <span className="playback-count">{fmtNum(visiblePositions.length)} aircraft</span>
          </div>
        )}
      </div>
      <div style={{ padding: '16px 24px', maxHeight: 300, overflow: 'auto', borderTop: '1px solid var(--border)' }}>
        {mode === 'live' ? (
          <>
            <h3 style={{ fontSize: 14, marginBottom: 8 }}>Live Timetable</h3>
            <DataTable data={flights} columns={timetableCols} maxRows={200} />
          </>
        ) : (
          <>
            <h3 style={{ fontSize: 14, marginBottom: 8 }}>
              Active Flights at {secToHMS(currentTime)} ({visiblePositions.length})
            </h3>
            <DataTable data={replayTableData} columns={['FLIGHT', 'ALTITUDE', 'SPEED', 'STATUS']} maxRows={200} />
          </>
        )}
      </div>
    </div>
  );
}
