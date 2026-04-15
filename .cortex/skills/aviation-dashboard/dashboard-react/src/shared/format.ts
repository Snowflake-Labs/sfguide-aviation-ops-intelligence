export function fmtDec(v: unknown, decimals = 1): string {
  const n = Number(v);
  if (v == null || v === '' || isNaN(n)) return '—';
  return n.toFixed(decimals);
}

export function fmtNum(v: unknown): string {
  const n = Number(v);
  if (v == null || v === '' || isNaN(n)) return '—';
  return n.toLocaleString();
}

export function fmtPct(v: unknown, decimals = 1): string {
  const n = Number(v);
  if (v == null || v === '' || isNaN(n)) return '—';
  return `${n.toFixed(decimals)}%`;
}

export function fmtDuration(minutes: number): string {
  if (!Number.isFinite(minutes)) return '—';
  const h = Math.floor(minutes / 60);
  const m = Math.round(minutes % 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export function fmtAltitude(ft: unknown): string {
  const n = Number(ft);
  if (ft == null || ft === '' || isNaN(n)) return '—';
  return `${n.toLocaleString()} ft`;
}

export function fmtSpeed(kts: unknown): string {
  const n = Number(kts);
  if (kts == null || kts === '' || isNaN(n)) return '—';
  return `${Math.round(n)} kts`;
}
