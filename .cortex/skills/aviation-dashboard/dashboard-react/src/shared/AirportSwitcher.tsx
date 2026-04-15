import { ChevronDown, Plane } from 'lucide-react';
import { useState, useRef, useEffect } from 'react';
import { useAirport } from '../hooks/useAirport';

export default function AirportSwitcher() {
  const { airport, airports, setAirport } = useAirport();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const displayName = airport ? airport.replace('AIRPORT_', '') : 'Select Airport';

  return (
    <div className="region-switcher" ref={ref}>
      <button className="region-trigger" onClick={() => setOpen(!open)}>
        <Plane size={14} />
        <span>{displayName}</span>
        <ChevronDown size={12} className={open ? 'rotated' : ''} />
      </button>
      {open && (
        <div className="region-dropdown">
          {airports.map((a) => (
            <button
              key={a.name}
              className={`region-option ${a.name === airport ? 'active' : ''}`}
              onClick={() => {
                setAirport(a.name);
                setOpen(false);
              }}
            >
              <Plane size={12} />
              <span>{a.iata}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
