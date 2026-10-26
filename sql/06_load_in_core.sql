
-- BEGIN;
-- CALL core.step_06_load_in_core();
-- SELECT COUNT(*) AS loaded_events FROM core.shipment_event;

-- COMMIT;

CREATE OR REPLACE PROCEDURE core.step_06_load_in_core()
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN

-- 0. Очистка перед загрузкой
TRUNCATE TABLE core.city RESTART identity CASCADE;
TRUNCATE TABLE core.person RESTART identity CASCADE;
TRUNCATE TABLE core.route RESTART identity CASCADE;
TRUNCATE TABLE core.shipment RESTART identity CASCADE;
TRUNCATE TABLE core.event_status RESTART identity CASCADE;
TRUNCATE TABLE core.shipment_event RESTART identity CASCADE;

-- 1. Загрузка в core.city
--    city_id генерируется по порядку: 1, 2, 3, ...
--    Порядок задаём по city_norm (файл уже отсортирован по нему),
--    чтобы нумерация была воспроизводимой.
INSERT INTO core.city (city_id, city_name)
SELECT
    ROW_NUMBER() OVER (ORDER BY s.city_norm)::SMALLINT AS city_id,
    s.city_name
FROM core.ref_city s
-- защита от повторной загрузки, если city_name уже есть
WHERE NOT EXISTS (
    SELECT 1 FROM core.city c WHERE c.city_name = s.city_name
);

-- 1.1. Контроль
--SELECT city_id, city_name FROM core.city ORDER BY city_id;


-- 2. Загрузка в core.person
INSERT INTO core.person (
    person_id,
    person_code,
    last_name,
    first_name,
    patronymic,
    city_id
)
SELECT
    s.person_no                         AS person_id,
    LPAD(s.person_no::text, 3, '0')     AS person_code,  -- CHAR(3), например '001'
    s.last_name,
    s.first_name,
    NULLIF(s.patronymic, '')            AS patronymic,   -- пустая строка -> NULL
    c.city_id
FROM core.ref_person s
JOIN core.city c
  ON c.city_name = s.city_name;

-- 2.1. Контроль
--SELECT COUNT(*) AS loaded_rows FROM core.person;

-- 3. Загрузка в core.route
INSERT INTO core.route (route_id, from_city_id, to_city_id)
SELECT
    (COALESCE((SELECT MAX(route_id) FROM core.route), 0)
     + ROW_NUMBER() OVER (ORDER BY fc.city_id, tc.city_id))::INT AS route_id,
    fc.city_id AS from_city_id,
    tc.city_id AS to_city_id
FROM (
    SELECT DISTINCT route_from, route_to
    FROM core.stg_event_clean
    WHERE route_from IS NOT NULL
      AND route_to   IS NOT NULL
) s
JOIN core.city fc ON fc.city_name = s.route_from
JOIN core.city tc ON tc.city_name = s.route_to
WHERE NOT EXISTS (
    SELECT 1
    FROM core.route r
    WHERE r.from_city_id = fc.city_id
      AND r.to_city_id   = tc.city_id
);

-- 3.1. Контроль
--SELECT r.route_id,
--       fc.city_name AS from_city,
--       tc.city_name AS to_city
--FROM core.route r
--JOIN core.city fc ON fc.city_id = r.from_city_id
--JOIN core.city tc ON tc.city_id = r.to_city_id
--ORDER BY r.route_id;
    
-- 4. Заполнение таблицы core.event_status
INSERT INTO core.event_status (status_id, status_code, status_name, seq_no, is_terminal)
VALUES
    (1, 'CREATED',           'Создано',             1, false),
    (2, 'ACCEPTED',          'Принято',             2, false),
    (3, 'SORTING',           'Сортировочный центр', 3, false),
    (4, 'IN_TRANSIT',        'В пути',              4, false),
    (5, 'HANDED_TO_COURIER', 'Передано курьеру',    5, false),
    (6, 'DELIVERED',         'Доставлено',          6, true);

-- 4.1. Контроль
--SELECT * FROM core.event_status ORDER BY status_id;


-- 5. Заполнение таблицы core.shipment
INSERT INTO core.shipment (
    shipment_id,
    sender_person_id,
    receiver_person_id,
    courier_person_id,
    route_id
)
SELECT
    base.shipment_id,
    base.sender_no,
    base.receiver_no,
    courier.courier_no,          -- NULL, если нет строки со status_seq = 5
    base.route_id
FROM (
    -- 1) одна строка на shipment: sender, receiver, route
    SELECT DISTINCT ON (s.shipment_id)
        s.shipment_id,
        s.sender_no,
        s.receiver_no,
        r.route_id
    FROM core.stg_event_clean s
    JOIN core.city sc ON sc.city_name = s.sender_city
    JOIN core.city rc ON rc.city_name = s.receiver_city
    JOIN core.route r  ON r.from_city_id = sc.city_id
                      AND r.to_city_id   = rc.city_id
    WHERE s.sender_no   IS NOT NULL
      AND s.receiver_no IS NOT NULL
    ORDER BY s.shipment_id, s.event_ts DESC
) base
LEFT JOIN (
    -- 2) курьер только из события status_seq = 5
    SELECT DISTINCT ON (s.shipment_id)
        s.shipment_id,
        s.courier_no
    FROM core.stg_event_clean s
    WHERE s.status_code = 'HANDED_TO_COURIER'
      AND s.courier_no IS NOT NULL
    ORDER BY s.shipment_id, s.event_ts DESC
) courier
  ON courier.shipment_id = base.shipment_id
ON CONFLICT (shipment_id) DO NOTHING;
 
-- Контроль
--SELECT sh.shipment_id,
--       sp.last_name || ' ' || sp.first_name AS sender,
--       rp.last_name || ' ' || rp.first_name AS receiver,
--       cp.last_name || ' ' || cp.first_name AS courier,
--       fc.city_name AS from_city,
--       tc.city_name AS to_city
--FROM core.shipment sh
--JOIN core.person sp ON sp.person_id = sh.sender_person_id
--JOIN core.person rp ON rp.person_id = sh.receiver_person_id
--LEFT JOIN core.person cp ON cp.person_id = sh.courier_person_id
--JOIN core.route r ON r.route_id = sh.route_id
--JOIN core.city fc ON fc.city_id = r.from_city_id
--JOIN core.city tc ON tc.city_id = r.to_city_id
--ORDER BY sh.shipment_id;

-- 6. Заполнение таблицы core.shipment_event
INSERT INTO core.shipment_event (
    event_id,
    shipment_id,
    event_datetime,
    status_id,
    raw_hash
)
SELECT
    (COALESCE((SELECT MAX(event_id) FROM core.shipment_event), 0)
     + ROW_NUMBER() OVER (ORDER BY s.event_ts, s.shipment_id))::BIGINT AS event_id,
    s.shipment_id,
    s.event_ts,
    s.status_seq::SMALLINT,
    s.raw_row_id                                       -- CHAR(34), 'hash:N' как есть
FROM core.stg_event_clean s
WHERE s.outcome = 'LOAD'
  AND s.is_exact_duplicate = false
  AND s.event_ts   IS NOT NULL
  AND s.status_seq IS NOT NULL
  AND EXISTS (SELECT 1 FROM core.shipment     sh WHERE sh.shipment_id = s.shipment_id)
  AND EXISTS (SELECT 1 FROM core.event_status es WHERE es.status_id   = s.status_seq)
  AND EXISTS (SELECT 1 FROM core.stg_raw_row  rr WHERE rr.raw_row_id = s.raw_row_id)
ON CONFLICT (shipment_id, event_datetime, status_id) DO NOTHING;

-- Контроль
--SELECT COUNT(*) AS loaded_events FROM core.shipment_event;

END;
$$;