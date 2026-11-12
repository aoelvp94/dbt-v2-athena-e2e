-- Hive insert_overwrite incremental. The second run renders the
-- is_incremental() branch (marker e2e_is_incremental) and rewrites partitions.

{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    table_type='hive',
    format='parquet',
    partitioned_by=['order_date'],
    force_batch=true,
    table_properties={'write_compression': "'SNAPPY'"}
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
