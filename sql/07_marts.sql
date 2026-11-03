-- Этап 9. Витрины — шаг 06

SET search_path = core, public;

-- Пересоздание витрин (CASCADE удаляет v_q*)
DROP TABLE IF EXISTS core.mart_shipment      CASCADE;
DROP TABLE IF EXISTS core.mart_route_daily   CASCADE;
DROP TABLE IF EXISTS core.mart_courier_daily CASCADE;
DROP TABLE IF EXISTS core.mart_event_daily   CASCADE;

CREATE TABLE core.mart_shipment (
    shipment_id           text PRIMARY KEY,
    sender_id             smallint NOT NULL,
    sender_name           text NOT NULL,
    sender_city           text NOT NULL,
    receiver_id           smallint NOT NULL,
    receiver_name         text NOT NULL,
    receiver_city         text NOT NULL,
    courier_id            smallint,
    courier_name          text,
    route_id              smallint NOT NULL,
    route_name            text NOT NULL,          -- «Москва → Казань»
    from_city             text NOT NULL,
    to_city               text NOT NULL,
    is_same_city          boolean NOT NULL,
    is_self_shipment      boolean NOT NULL,
    created_at            timestamp,              -- время этапа
    accepted_at           timestamp,
    sorting_at            timestamp,
    in_transit_at         timestamp,
    handed_to_courier_at  timestamp,
    delivered_at          timestamp,
    first_event_at        timestamp NOT NULL,
    last_event_at         timestamp NOT NULL,
    first_event_date      date NOT NULL,
    last_status_code      text NOT NULL,
    last_status_name      text NOT NULL,
    last_status_seq       smallint NOT NULL,
    events_loaded         int NOT NULL,           -- событий в core
    stages_loaded         int NOT NULL,           -- базовых этапов из 5
    missing_stages        text,                   -- отсутствующие этапы
    is_complete_chain     boolean NOT NULL,       -- все 5 этапов
    reached_courier       boolean NOT NULL,       -- дошла до курьера
    lead_time_hours       numeric(8,2),           -- срок, ч
    event_flags           int NOT NULL,           -- флаги событий
    shipment_flags        text,                   -- флаги посылки
    raw_rows              int NOT NULL,           -- строк RAW
    quarantined_rows      int NOT NULL,           -- из них карантин
    duplicate_rows        int NOT NULL            -- из них дубли
);

CREATE TABLE core.mart_route_daily (
    report_date           date NOT NULL,          -- день первого события
    route_id              smallint NOT NULL,
    route_name            text NOT NULL,
    from_city             text NOT NULL,
    to_city               text NOT NULL,
    shipments             int NOT NULL,
    reached_courier       int NOT NULL,
    complete_chain        int NOT NULL,
    without_courier       int NOT NULL,
    events_loaded         int NOT NULL,
    quarantined_rows      int NOT NULL,
    avg_lead_time_hours   numeric(8,2),
    PRIMARY KEY (report_date, route_id)
);

CREATE TABLE core.mart_courier_daily (
    report_date           date NOT NULL,          -- день передачи курьеру
    courier_id            smallint NOT NULL,
    courier_name          text NOT NULL,
    shipments             int NOT NULL,
    handed_events         int NOT NULL,           -- с событием передачи
    routes                int NOT NULL,
    cities                int NOT NULL,           -- городов назначения
    avg_lead_time_hours   numeric(8,2),
    PRIMARY KEY (report_date, courier_id)
);

CREATE TABLE core.mart_event_daily (
    event_date            date NOT NULL,
    status_id             smallint NOT NULL,
    status_code           text NOT NULL,
    status_name           text NOT NULL,
    events                int NOT NULL,
    shipments             int NOT NULL,
    flagged_events        int NOT NULL,
    PRIMARY KEY (event_date, status_id)
);

COMMENT ON TABLE core.mart_shipment      IS 'Этап 9. Витрина посылок: 1 строка = 1 посылка';
COMMENT ON TABLE core.mart_route_daily   IS 'Этап 9. Маршрут × день создания посылки';
COMMENT ON TABLE core.mart_courier_daily IS 'Этап 9. Курьер × день передачи курьеру';
COMMENT ON TABLE core.mart_event_daily   IS 'Этап 9. Поток событий: день × этап';

-- Шаг 06
CREATE OR REPLACE FUNCTION core.step_06_build_marts()
RETURNS int
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE n int;
BEGIN
    TRUNCATE core.mart_shipment, core.mart_route_daily, core.mart_courier_daily, core.mart_event_daily;

    -- Посылки
    INSERT INTO core.mart_shipment
    WITH ev AS (
        SELECT e.shipment_id,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'CREATED')           AS created_at,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'ACCEPTED')          AS accepted_at,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'SORTING')           AS sorting_at,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'IN_TRANSIT')        AS in_transit_at,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'HANDED_TO_COURIER') AS handed_at,
               min(e.event_datetime) FILTER (WHERE st.status_code = 'DELIVERED')         AS delivered_at,
               min(e.event_datetime) AS first_event_at,
               max(e.event_datetime) AS last_event_at,
               (array_agg(st.status_code ORDER BY e.event_datetime DESC, st.seq_no DESC))[1] AS last_code,
               (array_agg(st.status_name ORDER BY e.event_datetime DESC, st.seq_no DESC))[1] AS last_name,
               (array_agg(st.seq_no      ORDER BY e.event_datetime DESC, st.seq_no DESC))[1] AS last_seq,
               count(*) AS events_loaded,
               count(DISTINCT e.status_id) FILTER (WHERE NOT st.is_terminal) AS stages_loaded
          FROM core.shipment_event e
          JOIN core.event_status st ON st.status_id = e.status_id
         GROUP BY e.shipment_id
    ),
    miss AS (
        SELECT sh.shipment_id, string_agg(st.status_code, ',' ORDER BY st.seq_no) AS missing
          FROM core.shipment sh
         CROSS JOIN core.event_status st
         WHERE NOT st.is_terminal
           AND NOT EXISTS (SELECT 1 FROM core.shipment_event e
                            WHERE e.shipment_id = sh.shipment_id AND e.status_id = st.status_id)
         GROUP BY sh.shipment_id
    ),
    sfl AS (
        SELECT shipment_id, string_agg(flag_code, ',' ORDER BY flag_code) AS flags
          FROM core.shipment_quality_flag GROUP BY shipment_id
    ),
    efl AS (
        SELECT e.shipment_id, count(*) AS n
          FROM core.event_quality_flag f
          JOIN core.shipment_event e ON e.event_id = f.event_id
         GROUP BY e.shipment_id
    ),
    raw AS (
        SELECT shipment_id,
               count(*) AS raw_rows,
               count(*) FILTER (WHERE outcome = 'QUARANTINE') AS q_rows,
               count(*) FILTER (WHERE outcome = 'DUPLICATE')  AS d_rows
          FROM core.stg_event_clean
         WHERE shipment_id IS NOT NULL
         GROUP BY shipment_id
    ),
    base_cnt AS (SELECT count(*) AS n FROM core.event_status WHERE NOT is_terminal)
    SELECT sh.shipment_id,
           sp.person_id, concat_ws(' ', sp.last_name, sp.first_name, sp.patronymic), sc.city_name,
           rp.person_id, concat_ws(' ', rp.last_name, rp.first_name, rp.patronymic), rc.city_name,
           cp.person_id, concat_ws(' ', cp.last_name, cp.first_name, cp.patronymic),
           r.route_id, fc.city_name || ' → ' || tc.city_name, fc.city_name, tc.city_name,
           r.from_city_id = r.to_city_id,
           sh.sender_person_id = sh.receiver_person_id,
           ev.created_at, ev.accepted_at, ev.sorting_at, ev.in_transit_at, ev.handed_at, ev.delivered_at,
           ev.first_event_at, ev.last_event_at, ev.first_event_at::date,
           ev.last_code, ev.last_name, ev.last_seq,
           ev.events_loaded, ev.stages_loaded, miss.missing,
           ev.stages_loaded = base_cnt.n,
           ev.handed_at IS NOT NULL,
           round(extract(epoch FROM ev.handed_at - ev.created_at) / 3600, 2),
           coalesce(efl.n, 0), sfl.flags,
           coalesce(raw.raw_rows, 0), coalesce(raw.q_rows, 0), coalesce(raw.d_rows, 0)
      FROM core.shipment sh
      JOIN ev               ON ev.shipment_id = sh.shipment_id
      JOIN core.person sp   ON sp.person_id = sh.sender_person_id
      JOIN core.city   sc   ON sc.city_id   = sp.city_id
      JOIN core.person rp   ON rp.person_id = sh.receiver_person_id
      JOIN core.city   rc   ON rc.city_id   = rp.city_id
      LEFT JOIN core.person cp ON cp.person_id = sh.courier_person_id
      JOIN core.route  r    ON r.route_id   = sh.route_id
      JOIN core.city   fc   ON fc.city_id   = r.from_city_id
      JOIN core.city   tc   ON tc.city_id   = r.to_city_id
      LEFT JOIN miss        ON miss.shipment_id = sh.shipment_id
      LEFT JOIN sfl         ON sfl.shipment_id  = sh.shipment_id
      LEFT JOIN efl         ON efl.shipment_id  = sh.shipment_id
      LEFT JOIN raw         ON raw.shipment_id  = sh.shipment_id
     CROSS JOIN base_cnt;

    -- Маршрут × день
    INSERT INTO core.mart_route_daily
    SELECT first_event_date, route_id, route_name, from_city, to_city,
           count(*),
           count(*) FILTER (WHERE reached_courier),
           count(*) FILTER (WHERE is_complete_chain),
           count(*) FILTER (WHERE courier_id IS NULL),
           sum(events_loaded),
           sum(quarantined_rows),
           round(avg(lead_time_hours), 2)
      FROM core.mart_shipment
     GROUP BY first_event_date, route_id, route_name, from_city, to_city;

    -- Курьер × день
    INSERT INTO core.mart_courier_daily
    SELECT coalesce(handed_to_courier_at, last_event_at)::date, courier_id, courier_name,
           count(*),
           count(*) FILTER (WHERE reached_courier),
           count(DISTINCT route_id),
           count(DISTINCT to_city),
           round(avg(lead_time_hours), 2)
      FROM core.mart_shipment
     WHERE courier_id IS NOT NULL
     GROUP BY 1, courier_id, courier_name;

    -- День × этап
    INSERT INTO core.mart_event_daily
    SELECT e.event_datetime::date, st.status_id, st.status_code, st.status_name,
           count(*),
           count(DISTINCT e.shipment_id),
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM core.event_quality_flag f WHERE f.event_id = e.event_id))
      FROM core.shipment_event e
      JOIN core.event_status st ON st.status_id = e.status_id
     GROUP BY 1, st.status_id, st.status_code, st.status_name;

    SELECT count(*) INTO n FROM core.mart_shipment;
    RETURN n;
END;
$$;
