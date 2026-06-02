interface HeatmapGridProps {
  data: { row: string; col: string; value: number }[];
  rowLabels: string[];
  colLabels: string[];
  title?: string;
}

function heatColor(value: number, max: number): string {
  if (max === 0 || value === 0) return 'var(--surface)';
  const t = Math.min(value / max, 1);
  if (t < 0.5) {
    const r = Math.round(26 + (41 - 26) * (t * 2));
    const g = Math.round(35 + (181 - 35) * (t * 2));
    const b = Math.round(50 + (232 - 50) * (t * 2));
    return `rgb(${r},${g},${b})`;
  }
  const r = Math.round(41 + (229 - 41) * ((t - 0.5) * 2));
  const g = Math.round(181 + (161 - 181) * ((t - 0.5) * 2));
  const b = Math.round(232 + (0 - 232) * ((t - 0.5) * 2));
  return `rgb(${r},${g},${b})`;
}

export default function HeatmapGrid({ data, rowLabels, colLabels, title }: HeatmapGridProps) {
  const lookup = new Map<string, number>();
  let maxVal = 0;
  data.forEach(d => {
    const key = `${d.row}:${d.col}`;
    lookup.set(key, d.value);
    if (d.value > maxVal) maxVal = d.value;
  });

  return (
    <div>
      {title && <h4 style={{ fontSize: 12, marginBottom: 6 }}>{title}</h4>}
      <div style={{ overflowX: 'auto' }}>
        <div style={{
          display: 'grid',
          gridTemplateColumns: `40px repeat(${colLabels.length}, 1fr)`,
          gap: 1,
          fontSize: 9,
        }}>
          <div />
          {colLabels.map(c => (
            <div key={c} style={{ textAlign: 'center', color: 'var(--text-secondary)', padding: '2px 0' }}>{c}</div>
          ))}
          {rowLabels.map(row => (
            <>
              <div key={`l-${row}`} style={{ display: 'flex', alignItems: 'center', color: 'var(--text-secondary)', paddingRight: 4, justifyContent: 'flex-end' }}>{row}</div>
              {colLabels.map(col => {
                const val = lookup.get(`${row}:${col}`) || 0;
                return (
                  <div
                    key={`${row}:${col}`}
                    title={`${row} ${col}: ${val}`}
                    style={{
                      backgroundColor: heatColor(val, maxVal),
                      borderRadius: 2,
                      minHeight: 18,
                      minWidth: 14,
                    }}
                  />
                );
              })}
            </>
          ))}
        </div>
      </div>
    </div>
  );
}

export const DOW_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export const HOUR_LABELS = Array.from({ length: 24 }, (_, i) => String(i));
