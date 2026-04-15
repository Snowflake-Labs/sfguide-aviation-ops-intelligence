import { createContext, useContext, useState, useEffect, type ReactNode } from 'react';
import { useSnowflake } from './useSnowflake';

interface AirportInfo {
  name: string;
  iata: string;
}

interface AirportContextType {
  airport: string;
  airports: AirportInfo[];
  setAirport: (db: string) => void;
  loading: boolean;
}

const AirportContext = createContext<AirportContextType>({
  airport: '',
  airports: [],
  setAirport: () => {},
  loading: true,
});

export function AirportProvider({ children }: { children: ReactNode }) {
  const { query } = useSnowflake();
  const [airport, setAirport] = useState('');
  const [airports, setAirports] = useState<AirportInfo[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      try {
        const rows = await query("SHOW DATABASES LIKE 'AIRPORT_%'");
        const list: AirportInfo[] = (rows || [])
          .map((r: any) => {
            const name = r.name || r.NAME || '';
            const iata = name.replace('AIRPORT_', '');
            return { name, iata };
          })
          .filter((a: AirportInfo) => a.name);
        setAirports(list);
        if (list.length > 0 && !airport) {
          setAirport(list[0].name);
        }
      } catch {
        setAirports([]);
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  return (
    <AirportContext.Provider value={{ airport, airports, setAirport, loading }}>
      {children}
    </AirportContext.Provider>
  );
}

export function useAirport() {
  return useContext(AirportContext);
}
