-- Airport Search Query
-- Searches Overture Maps infrastructure for airports matching {SEARCH} term.
-- Replace {SEARCH} with user's search text (airport name, city, IATA, or ICAO code).
-- Returns up to 20 matching airports with name, IATA, ICAO, and class.
-- Results prioritize exact IATA/ICAO code matches over substring name matches.

SELECT
    i.id AS AIRPORT_ID,
    COALESCE(
        MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
        i.names:primary::STRING
    ) AS AIRPORT_NAME,
    i.class AS AIRPORT_CLASS,
    COALESCE(
        MAX(IFF(LOWER(t.value:"key"::STRING) IN ('iata','iata_code','iata:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
        ''
    ) AS AIRPORT_CODE_IATA,
    COALESCE(
        MAX(IFF(LOWER(t.value:"key"::STRING) IN ('icao','icao_code','icao:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
        ''
    ) AS AIRPORT_CODE_ICAO,
    CASE
        WHEN UPPER(MAX(IFF(LOWER(t.value:"key"::STRING) IN ('iata','iata_code','iata:code'),
             NULLIF(TRIM(t.value:"value"::STRING), ''), NULL))) = UPPER('{SEARCH}') THEN 1
        WHEN UPPER(MAX(IFF(LOWER(t.value:"key"::STRING) IN ('icao','icao_code','icao:code'),
             NULLIF(TRIM(t.value:"value"::STRING), ''), NULL))) = UPPER('{SEARCH}') THEN 2
        ELSE 3
    END AS SEARCH_RANK
FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
    , LATERAL FLATTEN(input => i.names:"common":"key_value", OUTER => TRUE) n
    , LATERAL FLATTEN(
        input => IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)):"key_value",
        OUTER => TRUE
    ) t
WHERE i.class IN ('international_airport','airport','regional_airport','municipal_airport','military_airport','private_airport','seaplane_airport','airstrip')
  AND i.subtype ILIKE '%airport%'
  AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
GROUP BY i.id, i.names:primary::STRING, i.class
HAVING COALESCE(
        MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
        i.names:primary::STRING
    ) ILIKE '%{SEARCH}%'
    OR MAX(IFF(LOWER(t.value:"key"::STRING) IN ('iata','iata_code','iata:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)) ILIKE '%{SEARCH}%'
    OR MAX(IFF(LOWER(t.value:"key"::STRING) IN ('icao','icao_code','icao:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)) ILIKE '%{SEARCH}%'
ORDER BY SEARCH_RANK, AIRPORT_NAME
LIMIT 20;
