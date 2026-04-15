export interface FlightRow {
  FLIGHT: string;
  ICAO24: string;
  LATITUDE: number;
  LONGITUDE: number;
  ALTITUDE_BARO_FT: number;
  GROUND_SPEED_KTS: number;
  DIRECTION: string;
  CALLSIGN: string;
  ON_GROUND: boolean;
  EVENT_TIME: string;
}

export interface AirportMeta {
  IATA: string;
  ICAO: string;
  NAME: string;
  LAT: number;
  LON: number;
  ZOOM: number;
  TIMEZONE: string;
  BBOX_MIN_LON: number;
  BBOX_MIN_LAT: number;
  BBOX_MAX_LON: number;
  BBOX_MAX_LAT: number;
}
