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

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_DATETIME_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

export function toDate(v: unknown): Date | null {
  if (v == null || v === '') return null;
  if (v instanceof Date) return isNaN(v.getTime()) ? null : v;
  const s = String(v).trim();
  if (ISO_DATE_RE.test(s)) return new Date(s + 'T00:00:00');
  if (ISO_DATETIME_RE.test(s)) return new Date(s.replace(' ', 'T'));
  const n = Number(s);
  if (!isNaN(n) && isFinite(n) && Math.abs(n) > 1e9) {
    const ms = Math.abs(n) > 1e12 ? n : n * 1000;
    const d = new Date(ms);
    if (!isNaN(d.getTime()) && d.getFullYear() >= 2000 && d.getFullYear() <= 2100) return d;
  }
  return null;
}

export function fmtDate(v: unknown): string {
  const d = toDate(v);
  if (!d) return '—';
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function fmtTime(v: unknown): string {
  const d = toDate(v);
  if (!d) return '—';
  return d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
}

export function fmtDateTime(v: unknown): string {
  const d = toDate(v);
  if (!d) return '—';
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ' ' +
    d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
}

export function fmtChartDate(v: unknown): string {
  const d = toDate(v);
  if (!d) return String(v ?? '');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}
