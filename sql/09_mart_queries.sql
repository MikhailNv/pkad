-- Этап 10. Запросы к витринам (core.v_q01…v_q10)

SET search_path = core, public;

-- Q01. Динамика по дням
CREATE OR REPLACE VIEW core.v_q01_daily_dynamics AS
SELECT d.event_date,
       sum(d.events) FILTER (WHERE d.status_code = 'CREATED')           AS created,
       sum(d.events) FILTER (WHERE d.status_code = 'ACCEPTED')          AS accepted,
       sum(d.events) FILTER (WHERE d.status_code = 'SORTING')           AS sorting,
       sum(d.events) FILTER (WHERE d.status_code = 'IN_TRANSIT')        AS in_transit,
       sum(d.events) FILTER (WHERE d.status_code = 'HANDED_TO_COURIER') AS handed_to_courier,
       sum(d.events)                                                    AS events_total,
       sum(d.flagged_events)                                            AS flagged_events,
       (SELECT count(*) FROM core.mart_shipment s WHERE s.first_event_date = d.event_date) AS new_shipments
  FROM core.mart_event_daily d
 GROUP BY d.event_date
 ORDER BY d.event_date;

-- Q02. Воронка этапов
CREATE OR REPLACE VIEW core.v_q02_status_funnel AS
WITH t AS (SELECT count(*) AS total FROM core.mart_shipment),
f AS (
    SELECT 1 AS seq_no, 'CREATED' AS status_code, count(*) FILTER (WHERE created_at IS NOT NULL) AS reached,
           count(*) FILTER (WHERE last_status_code = 'CREATED') AS stopped FROM core.mart_shipment
    UNION ALL SELECT 2, 'ACCEPTED', count(*) FILTER (WHERE accepted_at IS NOT NULL),
           count(*) FILTER (WHERE last_status_code = 'ACCEPTED') FROM core.mart_shipment
    UNION ALL SELECT 3, 'SORTING', count(*) FILTER (WHERE sorting_at IS NOT NULL),
           count(*) FILTER (WHERE last_status_code = 'SORTING') FROM core.mart_shipment
    UNION ALL SELECT 4, 'IN_TRANSIT', count(*) FILTER (WHERE in_transit_at IS NOT NULL),
           count(*) FILTER (WHERE last_status_code = 'IN_TRANSIT') FROM core.mart_shipment
    UNION ALL SELECT 5, 'HANDED_TO_COURIER', count(*) FILTER (WHERE handed_to_courier_at IS NOT NULL),
           count(*) FILTER (WHERE last_status_code = 'HANDED_TO_COURIER') FROM core.mart_shipment
    UNION ALL SELECT 6, 'DELIVERED', count(*) FILTER (WHERE delivered_at IS NOT NULL),
           count(*) FILTER (WHERE last_status_code = 'DELIVERED') FROM core.mart_shipment
)
SELECT f.seq_no, f.status_code,
       f.reached                                     AS shipments_with_stage,
       round(100.0 * f.reached / nullif(t.total, 0), 1) AS pct_of_shipments,
       f.stopped                                     AS last_stage_for_shipments
  FROM f CROSS JOIN t
 ORDER BY f.seq_no;

-- Q03. Рейтинг маршрутов
CREATE OR REPLACE VIEW core.v_q03_route_ranking AS
SELECT dense_rank() OVER (ORDER BY sum(shipments) DESC)            AS rank_by_volume,
       route_name,
       sum(shipments)                                              AS shipments,
       sum(reached_courier)                                        AS reached_courier,
       round(100.0 * sum(reached_courier) / sum(shipments), 1)     AS pct_reached_courier,
       round(100.0 * sum(complete_chain)  / sum(shipments), 1)     AS pct_complete_chain,
       round(sum(avg_lead_time_hours * reached_courier) / nullif(sum(reached_courier) FILTER (WHERE avg_lead_time_hours IS NOT NULL), 0), 2)
                                                                   AS avg_lead_time_hours,
       count(DISTINCT report_date)                                 AS active_days
  FROM core.mart_route_daily
 GROUP BY route_name
 ORDER BY rank_by_volume, route_name;

-- Q04. Нагрузка курьеров
CREATE OR REPLACE VIEW core.v_q04_courier_load AS
SELECT dense_rank() OVER (ORDER BY sum(shipments) DESC)            AS rank_by_volume,
       courier_id, courier_name,
       sum(shipments)                                              AS shipments,
       sum(handed_events)                                          AS handed_events,
       count(DISTINCT report_date)                                 AS active_days,
       round(sum(shipments)::numeric / count(DISTINCT report_date), 1) AS shipments_per_day,
       max(shipments)                                              AS max_per_day
  FROM core.mart_courier_daily
 GROUP BY courier_id, courier_name
 ORDER BY rank_by_volume, courier_id;

-- Q05. Потоки по городам
CREATE OR REPLACE VIEW core.v_q05_city_flows AS
WITH o AS (SELECT from_city AS city, count(*) AS n, count(*) FILTER (WHERE is_same_city) AS inner_n
             FROM core.mart_shipment GROUP BY from_city),
     i AS (SELECT to_city AS city, count(*) AS n FROM core.mart_shipment GROUP BY to_city)
SELECT coalesce(o.city, i.city)                    AS city,
       coalesce(o.n, 0)                            AS sent,
       coalesce(i.n, 0)                            AS received,
       coalesce(o.inner_n, 0)                      AS same_city,
       coalesce(i.n, 0) - coalesce(o.n, 0)         AS net_inflow
  FROM o FULL JOIN i ON i.city = o.city
 ORDER BY sent DESC, city;

-- Q06. Распределение сроков
CREATE OR REPLACE VIEW core.v_q06_lead_time_distribution AS
SELECT CASE WHEN lead_time_hours IS NULL THEN 'нет одного из этапов'
            WHEN lead_time_hours <  24   THEN '< 24 ч'
            WHEN lead_time_hours <  32   THEN '24–32 ч'
            WHEN lead_time_hours =  32   THEN '= 32 ч'
            WHEN lead_time_hours <= 48   THEN '32–48 ч'
            ELSE '> 48 ч' END                         AS lead_time_bucket,
       count(*)                                       AS shipments,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
       min(lead_time_hours)                           AS min_hours,
       max(lead_time_hours)                           AS max_hours
  FROM core.mart_shipment
 GROUP BY 1
 ORDER BY min(lead_time_hours) NULLS LAST;

-- Q07. Застрявшие посылки
CREATE OR REPLACE VIEW core.v_q07_stuck_shipments AS
WITH p AS (SELECT max(last_event_at) AS period_end FROM core.mart_shipment)
SELECT s.last_status_seq, s.last_status_code, s.last_status_name,
       count(*)                                                         AS shipments,
       count(*) FILTER (WHERE s.quarantined_rows > 0)                   AS with_quarantined_rows,
       round(avg(extract(epoch FROM p.period_end - s.last_event_at) / 3600)::numeric, 1) AS avg_hours_since_last_event
  FROM core.mart_shipment s CROSS JOIN p
 WHERE NOT s.reached_courier
 GROUP BY s.last_status_seq, s.last_status_code, s.last_status_name
 ORDER BY s.last_status_seq;

-- Q08. Качество по маршрутам
CREATE OR REPLACE VIEW core.v_q08_quality_by_route AS
SELECT route_name,
       count(*)                                                         AS shipments,
       round(100.0 * count(*) FILTER (WHERE NOT is_complete_chain) / count(*), 1) AS pct_incomplete_chain,
       count(*) FILTER (WHERE courier_id IS NULL)                       AS without_courier,
       sum(raw_rows)                                                    AS raw_rows,
       sum(quarantined_rows)                                            AS quarantined_rows,
       round(100.0 * sum(quarantined_rows) / nullif(sum(raw_rows), 0), 1) AS pct_quarantined_rows,
       sum(duplicate_rows)                                              AS duplicate_rows
  FROM core.mart_shipment
 GROUP BY route_name
 ORDER BY pct_quarantined_rows DESC, route_name;

-- Q09. Топ отправителей
CREATE OR REPLACE VIEW core.v_q09_top_senders AS
SELECT dense_rank() OVER (ORDER BY count(*) DESC)  AS rank_by_volume,
       sender_id, sender_name, sender_city,
       count(*)                                    AS shipments,
       count(DISTINCT receiver_id)                 AS receivers,
       count(DISTINCT to_city)                     AS destination_cities,
       count(*) FILTER (WHERE is_self_shipment)    AS self_shipments
  FROM core.mart_shipment
 GROUP BY sender_id, sender_name, sender_city
 ORDER BY rank_by_volume, sender_id;

-- Q10. Сверка витрин с core
CREATE OR REPLACE VIEW core.v_q10_reconciliation AS
SELECT check_name, mart_value, core_value,
       CASE WHEN check_name LIKE '%≤%' THEN mart_value <= core_value ELSE mart_value = core_value END AS is_ok
  FROM (
SELECT 'посылки: mart_shipment = core.shipment' AS check_name,
       (SELECT count(*) FROM core.mart_shipment)::bigint AS mart_value,
       (SELECT count(*) FROM core.shipment)::bigint      AS core_value
UNION ALL
SELECT 'события: Σ mart_shipment.events_loaded = core.shipment_event',
       (SELECT sum(events_loaded) FROM core.mart_shipment),
       (SELECT count(*) FROM core.shipment_event)
UNION ALL
SELECT 'события: Σ mart_event_daily.events = строки RAW с итогом LOAD',
       (SELECT sum(events) FROM core.mart_event_daily),
       (SELECT count(*) FROM core.raw_row_outcome WHERE outcome = 'LOAD')
UNION ALL
SELECT 'посылки: Σ mart_route_daily.shipments = core.shipment',
       (SELECT sum(shipments) FROM core.mart_route_daily),
       (SELECT count(*) FROM core.shipment)
UNION ALL
SELECT 'посылки с курьером: Σ mart_courier_daily.shipments = core.shipment',
       (SELECT sum(shipments) FROM core.mart_courier_daily),
       (SELECT count(*) FROM core.shipment WHERE courier_person_id IS NOT NULL)
UNION ALL
SELECT 'строки в карантине: Σ mart_shipment.quarantined_rows ≤ итог QUARANTINE (строки без распознанного номера посылки ни к какой посылке не относятся)',
       (SELECT sum(quarantined_rows) FROM core.mart_shipment),
       (SELECT count(*) FROM core.raw_row_outcome WHERE outcome = 'QUARANTINE')
) c;
