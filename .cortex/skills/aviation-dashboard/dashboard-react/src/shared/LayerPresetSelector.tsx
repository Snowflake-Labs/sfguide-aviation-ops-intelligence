import { useState } from 'react';
import type { LayerPreset } from './useInfrastructure';

interface LayerPresetSelectorProps {
  preset: LayerPreset;
  onPresetChange: (p: LayerPreset) => void;
  customTypes: Set<string>;
  onCustomTypesChange: (t: Set<string>) => void;
  availableTypes: string[];
}

const PRESETS: { value: LayerPreset; label: string }[] = [
  { value: 'none', label: 'None' },
  { value: 'airport-ops', label: 'Airport Ops' },
  { value: 'all', label: 'All' },
  { value: 'custom', label: 'Custom' },
];

export default function LayerPresetSelector({
  preset, onPresetChange, customTypes, onCustomTypesChange, availableTypes,
}: LayerPresetSelectorProps) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="form-group">
      <label>Map Layers</label>
      <select
        className="form-select"
        value={preset}
        onChange={e => onPresetChange(e.target.value as LayerPreset)}
      >
        {PRESETS.map(p => (
          <option key={p.value} value={p.value}>{p.label}</option>
        ))}
      </select>
      {preset === 'custom' && availableTypes.length > 0 && (
        <div style={{ marginTop: 6 }}>
          <button
            className="toggle-btn"
            onClick={() => setExpanded(!expanded)}
            style={{ fontSize: 11, color: 'var(--text-secondary)', cursor: 'pointer', background: 'none', border: 'none', padding: 0, textDecoration: 'underline' }}
          >
            {expanded ? 'Hide types' : `Select types (${customTypes.size}/${availableTypes.length})`}
          </button>
          {expanded && (
            <div style={{ maxHeight: 180, overflowY: 'auto', marginTop: 4, fontSize: 11 }}>
              {availableTypes.map(t => (
                <label key={t} style={{ display: 'flex', alignItems: 'center', gap: 4, padding: '2px 0', cursor: 'pointer' }}>
                  <input
                    type="checkbox"
                    checked={customTypes.has(t)}
                    onChange={e => {
                      const next = new Set(customTypes);
                      if (e.target.checked) next.add(t);
                      else next.delete(t);
                      onCustomTypesChange(next);
                    }}
                  />
                  {t}
                </label>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
