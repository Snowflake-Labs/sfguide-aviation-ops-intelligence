import { ChevronDown, Plane } from 'lucide-react';
import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { useAirport } from '../hooks/useAirport';

export default function AirportSwitcher() {
  const { airport, airports, setAirport } = useAirport();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [pos, setPos] = useState({ top: 0, left: 0 });

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        const dropdown = document.querySelector('.region-dropdown');
        if (dropdown && dropdown.contains(e.target as Node)) return;
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  useEffect(() => {
    if (open && triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      setPos({ top: rect.bottom + 6, left: rect.left });
    }
  }, [open]);

  const displayName = airport ? airport.replace('AIRPORT_', '') : 'Select Airport';

  return (
    <div className="region-switcher" ref={ref}>
      <button ref={triggerRef} className="region-trigger" onClick={() => setOpen(!open)}>
        <Plane size={14} />
        <span>{displayName}</span>
        <ChevronDown size={12} className={open ? 'rotated' : ''} />
      </button>
      {open && createPortal(
        <div className="region-dropdown" style={{ position: 'fixed', top: pos.top, left: pos.left }}>
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
        </div>,
        document.body
      )}
    </div>
  );
}
