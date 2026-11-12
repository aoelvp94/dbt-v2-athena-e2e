-- Passes with no rows when include_late_order is false.
-- After the second run (include_late_order true) it fails if order 99 is missing.
{{ config(severity='error') }}

{% if var('include_late_order', false) %}
select 1 as missing_late_order
where not exists (
    select 1
    from {{ ref('orders_incremental_iceberg') }}
    where order_id = 99
)
{% else %}
select 1 as missing_late_order
where false
{% endif %}
