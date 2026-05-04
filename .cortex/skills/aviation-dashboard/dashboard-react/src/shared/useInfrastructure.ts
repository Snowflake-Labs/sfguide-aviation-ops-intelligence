import { useMemo } from 'react';
import { GeoJsonLayer, ScatterplotLayer } from '@deck.gl/layers';
import { PathLayer } from '@deck.gl/layers';
import { useSfQuery } from '../hooks/useSnowflake';
import { useAirport } from '../hooks/useAirport';
import type { Layer } from '@deck.gl/core';

export type LayerPreset = 'none' | 'airport-ops' | 'all' | 'custom';

const AIRPORT_OPS_TYPES = new Set([
  'runway', 'taxiway', 'taxilane', 'gate', 'airport_gate', 'apron', 'helipad', 'jet_bridge', 'stopway',
]);

const BACKDROP_TYPES = new Set([
  'aerodrome', 'international_airport', 'terminal', 'building', 'parking', 'landuse', 'fence', 'wall', 'bridge',
]);

const TYPE_COLORS: Record<string, [number, number, number, number]> = {
  runway:       [100, 100, 100, 200],
  taxiway:      [255, 193, 7, 160],
  taxilane:     [255, 213, 79, 140],
  gate:         [41, 181, 232, 220],
  airport_gate: [41, 181, 232, 220],
  apron:        [158, 158, 158, 100],
  helipad:      [255, 152, 0, 200],
  jet_bridge:   [171, 71, 188, 180],
  stopway:      [229, 72, 77, 160],
  aerodrome:    [66, 66, 66, 60],
  international_airport: [66, 66, 66, 60],
  terminal:     [120, 120, 120, 80],
  fence:        [117, 117, 117, 140],
  wall:         [97, 97, 97, 160],
  parking:      [79, 195, 247, 100],
  bridge:       [161, 136, 127, 160],
  building:     [144, 164, 174, 80],
};

function getColor(type: string): [number, number, number, number] {
  return TYPE_COLORS[type] || [158, 158, 158, 120];
}

export interface InfrastructureFeature {
  TYPE: string;
  SUBTYPE: string;
  NAME: string;
  GEOJSON: string;
  GEOM_TYPE: string;
}

export function useInfrastructure(preset: LayerPreset, customTypes: Set<string> = new Set()) {
  const { airport } = useAirport();
  const db = airport ? `${airport}.PUBLIC` : '';

  const sql = airport && preset !== 'none'
    ? `SELECT CLASS AS TYPE, COALESCE(SUBTYPE, '') AS SUBTYPE,
              COALESCE(OSM_NAME, OSM_REF, PRIMARY_NAME, '') AS NAME,
              ST_ASGEOJSON(GEOMETRY) AS GEOJSON,
              CASE WHEN GEOMETRY_TYPE IN ('Polygon','MultiPolygon') THEN 'polygon'
                   WHEN GEOMETRY_TYPE IN ('LineString','MultiLineString') THEN 'line'
                   ELSE 'point' END AS GEOM_TYPE
       FROM ${db}.PROPERTIES_INFRASTRUCTURE`
    : '';
  const { data, loading } = useSfQuery<InfrastructureFeature>(sql, airport, 'PUBLIC');

  const visibleTypes = useMemo(() => {
    if (preset === 'none') return new Set<string>();
    if (preset === 'airport-ops') return AIRPORT_OPS_TYPES;
    if (preset === 'all') return new Set(data.map((d: any) => d.TYPE));
    return customTypes;
  }, [preset, customTypes, data]);

  const availableTypes = useMemo(() => {
    const s = new Set<string>();
    data.forEach((d: any) => s.add(d.TYPE));
    return Array.from(s).sort();
  }, [data]);

  const layers = useMemo((): Layer[] => {
    if (preset === 'none' || !data.length) return [];

    const filtered = data.filter((d: any) => visibleTypes.has(d.TYPE));
    const backdropPolygons: any[] = [];
    const opPolygons: any[] = [];
    const lines: any[] = [];
    const points: any[] = [];

    filtered.forEach((f: any) => {
      if (!f.GEOJSON) return;
      try {
        const geom = JSON.parse(f.GEOJSON);
        const feature = { type: 'Feature' as const, geometry: geom, properties: { type: f.TYPE, name: f.NAME } };
        if (f.GEOM_TYPE === 'polygon') {
          if (BACKDROP_TYPES.has(f.TYPE)) backdropPolygons.push(feature);
          else opPolygons.push(feature);
        }
        else if (f.GEOM_TYPE === 'line') lines.push(feature);
        else points.push(f);
      } catch { /* skip malformed */ }
    });

    const result: Layer[] = [];

    if (backdropPolygons.length) {
      result.push(new GeoJsonLayer({
        id: 'infra-backdrop',
        data: { type: 'FeatureCollection' as const, features: backdropPolygons },
        filled: false,
        stroked: true,
        getLineColor: (f: any) => {
          const c = getColor(f.properties?.type);
          return [c[0], c[1], c[2], 140] as [number, number, number, number];
        },
        getLineWidth: 1,
        lineWidthMinPixels: 1,
        pickable: false,
      }));
    }

    if (opPolygons.length) {
      result.push(new GeoJsonLayer({
        id: 'infra-polygons',
        data: { type: 'FeatureCollection' as const, features: opPolygons },
        getFillColor: (f: any) => {
          const c = getColor(f.properties?.type);
          return [c[0], c[1], c[2], 140] as [number, number, number, number];
        },
        getLineColor: (f: any) => getColor(f.properties?.type),
        getLineWidth: 2,
        lineWidthMinPixels: 1,
        pickable: true,
      }));
    }

    if (lines.length) {
      result.push(new GeoJsonLayer({
        id: 'infra-lines',
        data: { type: 'FeatureCollection' as const, features: lines },
        getLineColor: (f: any) => getColor(f.properties?.type),
        getLineWidth: 3,
        lineWidthMinPixels: 1,
        pickable: true,
      }));
    }

    if (points.length) {
      result.push(new ScatterplotLayer({
        id: 'infra-points',
        data: points,
        getPosition: (d: any) => {
          try {
            const geom = JSON.parse(d.GEOJSON);
            return geom.coordinates;
          } catch { return [0, 0]; }
        },
        getFillColor: (d: any) => getColor(d.TYPE),
        getRadius: 4,
        radiusMinPixels: 3,
        radiusMaxPixels: 8,
        pickable: true,
      }));
    }

    return result;
  }, [data, preset, visibleTypes]);

  return { layers, loading, availableTypes };
}
