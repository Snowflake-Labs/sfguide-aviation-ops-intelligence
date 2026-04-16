import { useState, useMemo } from 'react';
import { ChevronUp, ChevronDown } from 'lucide-react';
import { fmtDec, toDate, fmtDate, fmtDateTime } from './format';

const DATETIME_COLS = /^(LAST_SEEN|LAST_REFRESHED_AT|WINDOW_START|WINDOW_END|ENTRY|EXIT|.*_SCHEDULED)$/i;
const DATE_COLS = /^(DATE|DT|METRIC_DATE|SERVICE_DATE|.*_DATE)$/i;

function fmtCell(col: string, v: unknown): string {
  if (v == null || v === '') return '';
  if (DATETIME_COLS.test(col) && toDate(v)) return fmtDateTime(v);
  if (DATE_COLS.test(col) && toDate(v)) return fmtDate(v);
  const n = Number(v);
  if (v !== '' && !isNaN(n) && String(v).includes('.')) return fmtDec(v);
  return String(v);
}

interface DataTableProps {
  data: Record<string, any>[];
  columns?: string[];
  maxRows?: number;
}

export default function DataTable({ data, columns: explicitColumns, maxRows = 100 }: DataTableProps) {
  const [sortCol, setSortCol] = useState<string | null>(null);
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');

  const columns = useMemo(() => {
    if (explicitColumns) return explicitColumns;
    if (data.length === 0) return [];
    return Object.keys(data[0]);
  }, [data, explicitColumns]);

  const sorted = useMemo(() => {
    if (!sortCol) return data.slice(0, maxRows);
    return [...data].sort((a, b) => {
      const av = a[sortCol], bv = b[sortCol];
      if (av == null) return 1;
      if (bv == null) return -1;
      const cmp = !isNaN(Number(av)) && !isNaN(Number(bv)) ? Number(av) - Number(bv) : String(av).localeCompare(String(bv));
      return sortDir === 'asc' ? cmp : -cmp;
    }).slice(0, maxRows);
  }, [data, sortCol, sortDir, maxRows]);

  const handleSort = (col: string) => {
    if (sortCol === col) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortCol(col); setSortDir('asc'); }
  };

  if (data.length === 0) return <div className="data-table-empty">No data</div>;

  return (
    <div className="data-table-container">
      <table className="data-table">
        <thead>
          <tr>
            {columns.map(col => (
              <th key={col} onClick={() => handleSort(col)} className="data-table-th">
                {col}
                {sortCol === col && (sortDir === 'asc' ? <ChevronUp size={12} /> : <ChevronDown size={12} />)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.map((row, i) => (
            <tr key={i}>
              {columns.map(col => (
                <td key={col}>{fmtCell(col, row[col])}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {data.length > maxRows && <div className="data-table-overflow">Showing {maxRows} of {data.length} rows</div>}
    </div>
  );
}
