import { useState, useMemo } from 'react';

export interface VehicleTypeSelection {
  selected: Set<string>;
  allSelected: boolean;
}

interface Category {
  key: string;
  label: string;
  examples: string;
  desc: string;
}

const AIRCRAFT_CATEGORIES: Category[] = [
  { key: 'HEAVY_AIRCRAFT', label: 'Heavy', examples: 'A380, 747, 777', desc: 'Wake >136 t; long-haul intl' },
  { key: 'LARGE_AIRLINER', label: 'Large Airliner', examples: 'A321, 757, 767', desc: '34-136 t; medium-haul, high pax' },
  { key: 'MEDIUM_AIRCRAFT', label: 'Medium', examples: '737, A320 (cat A0)', desc: 'Typical narrow-body' },
  { key: 'SMALL_COMMUTER', label: 'Small Commuter', examples: 'ATR 72, Dash 8', desc: 'Regional turboprop / RJ' },
  { key: 'LIGHT_AIRCRAFT', label: 'Light', examples: 'C172, PA-28', desc: '<15.5 t; general aviation' },
  { key: 'HELICOPTER', label: 'Helicopter', examples: 'EC135, AW139', desc: 'Medical, corporate, tour' },
  { key: 'HIGH_PERFORMANCE_MILITARY', label: 'Military', examples: 'F-16, F-35', desc: 'Fighters / trainers (cat A6)' },
  { key: 'ULTRALIGHT_EXPERIMENTAL', label: 'Ultralight', examples: 'gliders, UAVs, balloons', desc: 'ADS-B cat B* (exp/ultralight)' },
];

const GROUND_CATEGORIES: Category[] = [
  { key: 'TOWER', label: 'Tower', examples: 'ATC towers', desc: 'Fixed ground stations (TYPE=TWR)' },
  { key: 'SERVICE_VEHICLE', label: 'Service Vehicle', examples: 'fuel, catering, pushback', desc: 'Ground support equipment' },
  { key: 'GROUND_VEHICLE', label: 'Ground Vehicle', examples: 'ops, follow-me cars', desc: 'Airport authority vehicles (C2)' },
  { key: 'LIGHT_SURFACE_VEHICLE', label: 'Light Surface', examples: 'emergency, utility', desc: 'Emergency / light surface (C1)' },
  { key: 'UNKNOWN_SURFACE', label: 'Unknown Surface', examples: 'unclassified', desc: 'ADS-B cat C0 (unknown)' },
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

  const toggleGroup = (group: Category[]) => {
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

  const renderCategoryRow = (c: Category) => (
    <label
      key={c.key}
      style={{
        display: 'flex',
        alignItems: 'flex-start',
        gap: 6,
        padding: '4px 0 4px 16px',
        cursor: 'pointer',
      }}
    >
      <input
        type="checkbox"
        checked={selected.has(c.key)}
        onChange={() => toggleOne(c.key)}
        style={{ marginTop: 2 }}
      />
      <div style={{ display: 'flex', flexDirection: 'column', lineHeight: 1.25 }}>
        <span>{c.label}</span>
        <span style={{ fontSize: 10, color: 'var(--text-secondary)' }}>
          {c.examples} - {c.desc}
        </span>
      </div>
    </label>
  );

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
        <div style={{ fontSize: 11, maxHeight: 360, overflowY: 'auto' }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '3px 0', cursor: 'pointer', fontWeight: 600 }}>
            <input type="checkbox" checked={allSelected} onChange={toggleAll} />
            All
          </label>
          <div style={{ marginTop: 4, fontWeight: 600, fontSize: 10, color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Aircraft</div>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 8px', cursor: 'pointer' }}>
            <input type="checkbox" checked={allAircraft} onChange={() => toggleGroup(AIRCRAFT_CATEGORIES)} />
            All Aircraft
          </label>
          {AIRCRAFT_CATEGORIES.map(renderCategoryRow)}
          <div style={{ marginTop: 4, fontWeight: 600, fontSize: 10, color: 'var(--text-secondary)', textTransform: 'uppercase' }}>Ground</div>
          <label style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0 2px 8px', cursor: 'pointer' }}>
            <input type="checkbox" checked={allGround} onChange={() => toggleGroup(GROUND_CATEGORIES)} />
            All Ground
          </label>
          {GROUND_CATEGORIES.map(renderCategoryRow)}
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
