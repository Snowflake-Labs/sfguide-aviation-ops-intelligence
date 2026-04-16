export const SNOWFLAKE_HOST = process.env.SNOWFLAKE_HOST || '';
export const IS_SPCS = !!SNOWFLAKE_HOST;
export const CONN = process.env.SNOWFLAKE_CONNECTION || '';
export let SF_WAREHOUSE = process.env.SNOWFLAKE_WAREHOUSE || 'MY_WH';
export function setWarehouse(name: string): void { SF_WAREHOUSE = name; }
export const QUERY_TAG = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":"1.0"}';
