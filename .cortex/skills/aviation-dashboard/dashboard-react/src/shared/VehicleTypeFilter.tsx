import { useState, useMemo } from 'react';

export interface VehicleTypeSelection {
  selected: Set<string>;
  allSelected: boolean;
}

const AIRCRAFT_CATEGORIES = [
  { key: 'HEAVY_AIRCRAFT', label: 'Heavy' },
  { key: 'LARGE_AIRLINER', label: 'Large Airliner' },
  { key: 'MEDIUM_AIRCRAFT', label: 'Medium' },
  { key: 'SMALL_COMMUTER', label: 'Small Commuter' },
  { key: 'LIGHT_AIRCRAFT', label: 'Light' },
  { key: 'HELICOPTER', label: 'Helicopter' },
  { key: 'HIGH_PERFORMANCE_MILITARY', label: 'Military' },
  { key: 'ULTRALIGHT_EXPERIMENTAL', label: 'Ultralight' },
];

const GROUND_CATEGORIES = [
  { key: 'TOWER', label: 'Tower' },
  { key: 'SERVICE_VEHICLE', label: 'Service Vehicle' },
  { key: 'GROUND_VEHICLE', label: 'Ground Vehicle' },
  { key: 'LIGHT_SURFACE_VEHICLE', label: 'Light Surface' },
  { key: 'UNKNOWN_SURFACE', label: 'Unknown Surface' },
];

const ALL_CATEGORIES = [...AIRCRAFT_CATEGORIES, ...GROUND_CATEGORIES].map(c => c.key);

interface VehicleTypeFilterProps {
  selected: Set<string>;
  onChange: (s: Set<string>) => void;
}

export default function VehicleTypeFilter({ selected, onChange }: VehicleTypeFilterProps) {
  const [expanded, setExpanded] = useState(false);

  const allAircraft = AIRCRAFT_CATEGORIES.every(c => selected.has(c.key));
  const allGround = GROUND_CATEGORIES.every(c => selected.has(c.key));
  const allSelected = allAircraft && allGround;

  const toggleAll = () => {
    if (allSelected) onChange(new Set());
    else onChange(new Set(ALL_CATEGORIES));
  };

  const toggleGroup = (group: typeof AIRCRAFT_CATEGORIES) => {
    const keys = group.map(c => c.key);
    const allIn = keys.every(k => selected.has(k));
    const next = new Set(selected);
    if (allIn) keys.forEach(k => next.delete(k));
    else keys.forEach(k => next.add(k));
    onChange(next);
  };

  const toggleOne = (key: string) => {
    const next = new Set(selected);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    onChange(next);
  };

  return (
    <div className="form-group">
      <label style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        Vehicle Types
        <button
          onClick={() => setExpanded(!expanded)}
          style={{ fontSize: 10, color: 'var(--text-secondary)', background: 'none', border: 'none', cursor: 'pointer', textDecoration: 'underline' }}
        >
          {expanded ? 'collapse' : `${selected.size}/${ALL_CATEGORIES.length}`}
        </button>
      </label>
      {!expanded && (
        <div style={{ fontSize: 11, color: 'var(--text-secondary)' }}>
          {allSelected ? 'All types' : `${selected.size} of ${ALL_CATEGORIES.length} selected`}
        </div>
      )}
      {expanded && (
        <div style={{ fontSize: 11, maxHeight: 240, overflowY: 'auto' }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '3px 0', cursor: 'pointer', fontWeight: 600 }}>
            <input type="checkbox" checked={allSelected} onChange={toggleAll} />
            All
          </label>
          <div style={{ marginTop: 4, fontWeight: 600, fontSize: 10, color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Aircraft</div>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 8px', cursor: 'pointer' }}>
            <input type="checkbox" checked={allAircraft} onChange={() => toggleGroup(AIRCRAFT_CATEGORIES)} />
            All Aircraft
          </label>
          {AIRCRAFT_CATEGORIES.map(c => (
            <label key={c.key} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 16px', cursor: 'pointer' }}>
              <input type="checkbox" checked={selected.has(c.key)} onChange={() => toggleOne(c.key)} />
              {c.label}
            </label>
          ))}
          <div style={{ marginTop: 4, fontWeight: 600, fontSize: 10, color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Ground</div>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 8px', cursor: 'pointer' }}>
            <input type="checkbox" checked={allGround} onChange={() => toggleGroup(GROUND_CATEGORIES)} />
            All Ground
          </label>
          {GROUND_CATEGORIES.map(c => (
            <label key={c.key} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 16px', cursor: 'pointer' }}>
              <input type="checkbox" checked={selected.has(c.key)} onChange={() => toggleOne(c.key)} />
              {c.label}
            </label>
          ))}
        </div>
      )}
    </div>
  );
}

export function useVehicleTypeFilter() {
  const [selected, setSelected] = useState<Set<string>>(new Set(ALL_CATEGORIES));
  const sqlFilter = useMemo(() => {
    if (selected.size === ALL_CATEGORIES.length || selected.size === 0) return '';
    const list = Array.from(selected).map(s => `'${s}'`).join(',');
    return `AND VEHICLE_CATEGORY IN (${list})`;
  }, [selected]);
  return { selected, setSelected, sqlFilter, allSelected: selected.size === ALL_CATEGORIES.length };
}
