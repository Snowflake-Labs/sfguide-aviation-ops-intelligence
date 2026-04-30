import { useState } from 'react';
import { AirportProvider } from './hooks/useAirport';
import AirportSwitcher from './shared/AirportSwitcher';
import Home from './components/Home';
import LiveView from './components/LiveView';
import FlightTracker from './components/FlightTracker';
import GroundActivity from './components/GroundActivity';
import RunwayCrossings from './components/RunwayCrossings';
import TrafficAnalysis from './components/TrafficAnalysis';
import GateAnalysis from './components/GateAnalysis';
import TSAThroughput from './components/TSAThroughput';
import Monitoring from './components/Monitoring';
import Performance from './components/Performance';
import {
  Radio, Plane, MapPin, AlertTriangle,
  BarChart3, DoorOpen, ShieldCheck, Activity, Gauge, Home as HomeIcon,
} from 'lucide-react';

type Page = 'home' | 'live' | 'tracker' | 'ground' | 'crossings' | 'traffic' | 'gates' | 'tsa' | 'monitoring' | 'performance';

const NAV: { section: string; items: { key: Page; label: string; icon: any }[] }[] = [
  {
    section: 'Operations',
    items: [
      { key: 'live', label: 'Live View', icon: Radio },
      { key: 'tracker', label: 'Flight Tracker', icon: Plane },
      { key: 'ground', label: 'Ground Activity', icon: MapPin },
    ],
  },
  {
    section: 'Analytics',
    items: [
      { key: 'traffic', label: 'Traffic Analysis', icon: BarChart3 },
      { key: 'gates', label: 'Gate Analysis', icon: DoorOpen },
      { key: 'crossings', label: 'Runway Crossings', icon: AlertTriangle },
      { key: 'tsa', label: 'TSA Throughput', icon: ShieldCheck },
      { key: 'performance', label: 'Performance', icon: Gauge },
    ],
  },
  {
    section: 'System',
    items: [
      { key: 'monitoring', label: 'Monitoring', icon: Activity },
    ],
  },
];

function renderPage(page: Page, navigateTo: (p: Page) => void) {
  switch (page) {
    case 'home': return <Home navigateTo={navigateTo} />;
    case 'live': return <LiveView />;
    case 'tracker': return <FlightTracker />;
    case 'ground': return <GroundActivity />;
    case 'crossings': return <RunwayCrossings />;
    case 'traffic': return <TrafficAnalysis />;
    case 'gates': return <GateAnalysis />;
    case 'tsa': return <TSAThroughput />;
    case 'monitoring': return <Monitoring />;
    case 'performance': return <Performance />;
    default: return <Home navigateTo={navigateTo} />;
  }
}

const FULL_WIDTH_PAGES: Page[] = ['live', 'tracker', 'ground'];

export default function App() {
  const [activePage, setActivePage] = useState<Page>('home');

  const navigateTo = (p: Page) => setActivePage(p);
  const isFullWidth = FULL_WIDTH_PAGES.includes(activePage);

  return (
    <AirportProvider>
      <div className="app">
        <div className="sidebar">
          <div className="sidebar-brand">
            <img src="/snowflake_h3.png" height="28" alt="" />
            <span>Aviation Ops</span>
          </div>
          <div style={{ padding: '10px 12px', borderBottom: '1px solid var(--border)' }}>
            <AirportSwitcher />
          </div>
          <div className="sidebar-nav">
            <button
              className={`sidebar-link ${activePage === 'home' ? 'active' : ''}`}
              onClick={() => navigateTo('home')}
            >
              <HomeIcon size={16} /> Home
            </button>
            {NAV.map(({ section, items }) => (
              <div key={section}>
                <div className="sidebar-section">{section}</div>
                {items.map(({ key, label, icon: Icon }) => (
                  <button
                    key={key}
                    className={`sidebar-link ${activePage === key ? 'active' : ''}`}
                    onClick={() => navigateTo(key)}
                  >
                    <Icon size={16} /> {label}
                  </button>
                ))}
              </div>
            ))}
          </div>
          <div className="sidebar-footer">
            <div className="sidebar-version">v1.1.1</div>
          </div>
        </div>
        <div className="app-content">
          <div className={`app-main${isFullWidth ? ' full-width' : ''}`}>
            {renderPage(activePage, navigateTo)}
          </div>
        </div>
      </div>
    </AirportProvider>
  );
}
