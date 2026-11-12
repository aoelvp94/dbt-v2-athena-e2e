-- Iceberg merge. The first run creates the table (is_incremental() is false).
-- The second run, with include_late_order true, merges order 99 in.

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    table_type='iceberg',
    unique_key='order_id',
    format='parquet',
    partitioned_by=['order_date'],
    table_properties={'write_target_data_file_size_bytes': "'1048576'"}
) }}

with src as (
    select
        order_id,
        customer_id,
        customer_name,
        status,
        amount_cents,
        order_date
    from {{ ref('stg_orders') }}
    {% if var('include_late_order', false) %}
    union all
    select
        99 as order_id,
        10 as customer_id,
        'ada' as customer_name,
        'placed' as status,
        100 as amount_cents,
        '2024-03-01' as order_date
    {% endif %}
)

select * from src
{% if is_incremental() %}
where order_date >= '2024-01-01'
    and 'e2e_is_incremental' = 'e2e_is_incremental'
{% endif %}
