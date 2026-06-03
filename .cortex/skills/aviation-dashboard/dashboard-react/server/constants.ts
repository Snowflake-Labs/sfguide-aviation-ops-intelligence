import { existsSync } from 'fs';

// Snowflake injects an OAuth token at this path inside any managed container
// (SPCS services and App Runtime Application Services alike).
const SPCS_TOKEN_PATH = '/snowflake/session/token';

export const SNOWFLAKE_HOST = process.env.SNOWFLAKE_HOST || '';
// Treat as in-container when the host env is present OR the injected token file
// exists. The token-file check makes static-file serving + the SQL REST path
// robust under App Runtime even if the host env var naming differs.
export const IS_SPCS = !!SNOWFLAKE_HOST || existsSync(SPCS_TOKEN_PATH);
export const CONN = process.env.SNOWFLAKE_CONNECTION || '';
export let SF_WAREHOUSE = process.env.SNOWFLAKE_WAREHOUSE || 'MY_WH';
export function setWarehouse(name: string): void { SF_WAREHOUSE = name; }
export const QUERY_TAG = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":"1.0"}';
