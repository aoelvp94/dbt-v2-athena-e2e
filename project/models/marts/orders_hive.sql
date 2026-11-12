-- Hive table. partitioned_by, table_properties and force_batch are set as
-- +keys in dbt_project.yml so parse covers that config path.

select
    order_id,
    customer_id,
    customer_name,
    status,
    amount_cents,
    order_date
from {{ ref('stg_orders') }}
