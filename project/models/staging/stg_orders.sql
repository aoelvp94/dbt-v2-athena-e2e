{{ config(materialized='view') }}

select
    cast(o.order_id as integer) as order_id,
    cast(o.customer_id as integer) as customer_id,
    c.customer_name,
    o.status,
    cast(o.amount_cents as integer) as amount_cents,
    cast(o.order_date as varchar) as order_date
from {{ ref('raw_orders') }} as o
inner join {{ ref('raw_customers') }} as c
    on o.customer_id = c.customer_id
where o.status <> 'cancelled'
