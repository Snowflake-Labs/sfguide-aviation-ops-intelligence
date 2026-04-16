import {
  Radio, Plane, MapPin, AlertTriangle,
  BarChart3, DoorOpen, ShieldCheck, Activity, Gauge,
} from 'lucide-react';

interface HomeProps {
  navigateTo: (page: any) => void;
}

const PAGES = [
  { key: 'live', label: 'Live View', icon: Radio, desc: 'Real-time aircraft positions and live timetable' },
  { key: 'tracker', label: 'Flight Tracker', icon: Plane, desc: 'Track individual flights with altitude-colored paths' },
  { key: 'ground', label: 'Ground Activity', icon: MapPin, desc: 'H3 hexagon density map of ground traffic' },
  { key: 'crossings', label: 'Runway Crossings', icon: AlertTriangle, desc: 'Runway crossing safety analytics and heatmaps' },
  { key: 'traffic', label: 'Traffic Analysis', icon: BarChart3, desc: 'Temporal traffic patterns and airline statistics' },
  { key: 'gates', label: 'Gate Analysis', icon: DoorOpen, desc: 'Gate utilization, dwell times, and airline breakdown' },
  { key: 'tsa', label: 'TSA Throughput', icon: ShieldCheck, desc: 'TSA checkpoint passenger throughput trends and patterns' },
  { key: 'performance', label: 'Performance', icon: Gauge, desc: 'Operational KPIs: taxi times, on-time rates' },
  { key: 'monitoring', label: 'Monitoring', icon: Activity, desc: 'System health, data freshness, and pipeline status' },
];

export default function Home({ navigateTo }: HomeProps) {
  return (
    <div className="page-dashboard">
      <h2>Aviation Ops Intelligence</h2>
      <p>Airport operations analytics powered by ADS-B data and flight schedules.</p>
      <div className="home-grid">
        {PAGES.map(({ key, label, icon: Icon, desc }) => (
          <button key={key} className="home-card" onClick={() => navigateTo(key)}>
            <div className="home-card-icon"><Icon size={24} /></div>
            <h3>{label}</h3>
            <p>{desc}</p>
          </button>
        ))}
      </div>
    </div>
  );
}
