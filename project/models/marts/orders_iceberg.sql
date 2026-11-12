-- Iceberg table. The same three config keys are set here, on the model,
-- which is the other path parse used to reject.

{{ config(
    materialized='table',
    table_type='iceberg',
    format='parquet',
    partitioned_by=['order_date'],
    table_properties={'write_target_data_file_size_bytes': "'1048576'"}
) }}

select
    order_id,
    customer_id,
    customer_name,
    status,
    amount_cents,
    order_date
from {{ ref('stg_orders') }}
