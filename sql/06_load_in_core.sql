-- Этап 7. Загрузка core — шаг 05

SET search_path = core, public;

-- Старое имя шага
DROP PROCEDURE IF EXISTS core.step_06_load_in_core();

-- UNIQUE (K9) для ранее созданных таблиц
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.shipment_event'::regclass AND conname = 'shipment_event_k2') THEN
        ALTER TABLE core.shipment_event ADD CONSTRAINT shipment_event_K2 UNIQUE (raw_hash);
    END IF;
END $$;

-- Справочник флагов качества
CREATE TABLE IF NOT EXISTS core.ref_quality_flag (
    flag_code   text PRIMARY KEY,
    flag_level  text NOT NULL CHECK (flag_level IN ('EVENT', 'SHIPMENT')),
    source      text NOT NULL CHECK (source IN ('STAGE_5', 'CORE')),
    description text NOT NULL
);

INSERT INTO core.ref_quality_flag (flag_code, flag_level, source, description) VALUES
    ('SENDER_EMPTY',                'EVENT',    'STAGE_5', 'В строке не указан отправитель (восстановлен по другим событиям посылки)'),
    ('RECEIVER_EMPTY',              'EVENT',    'STAGE_5', 'В строке не указан получатель (восстановлен по другим событиям посылки)'),
    ('COURIER_MISSING_ON_HANDOVER', 'EVENT',    'STAGE_5', 'Событие «Передано курьеру» без курьера'),
    ('SELF_SHIPMENT',               'SHIPMENT', 'STAGE_5', 'Отправитель и получатель — один и тот же человек'),
    ('SAME_CITY_DELIVERY',          'SHIPMENT', 'STAGE_5', 'Доставка внутри одного города'),
    ('NO_COURIER',                  'SHIPMENT', 'CORE',    'Курьер не определён ни по одному загруженному событию'),
    ('INCOMPLETE_CHAIN',            'SHIPMENT', 'CORE',    'Загружены не все базовые этапы «Создано» … «Передано курьеру» (часть строк в карантине или отсутствует в RAW)')
ON CONFLICT (flag_code) DO UPDATE
   SET flag_level = EXCLUDED.flag_level, source = EXCLUDED.source, description = EXCLUDED.description;

-- FK: флаги из справочника
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'core.event_quality_flag'::regclass AND conname = 'event_quality_flag_flag_fk') THEN
        ALTER TABLE core.event_quality_flag ADD CONSTRAINT event_quality_flag_flag_fk FOREIGN KEY (flag_code) REFERENCES core.ref_quality_flag (flag_code);
    END IF;
END $$;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'core.shipment_quality_flag'::regclass AND conname = 'shipment_quality_flag_flag_fk') THEN
        ALTER TABLE core.shipment_quality_flag ADD CONSTRAINT shipment_quality_flag_flag_fk FOREIGN KEY (flag_code) REFERENCES core.ref_quality_flag (flag_code);
    END IF;
END $$;

-- Шаг 05
CREATE OR REPLACE PROCEDURE core.step_05_load_core()
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    -- Полная пересборка
    TRUNCATE core.event_quality_flag, core.shipment_event, core.shipment_quality_flag,
             core.shipment, core.route, core.person, core.city, core.event_status;

    -- Статусы из ref_status
    INSERT INTO core.event_status (status_id, status_code, status_name, seq_no, is_terminal)
    SELECT s.seq_no, s.status_code, s.status_name, s.seq_no,
           s.seq_no = max(s.seq_no) OVER ()
      FROM core.ref_status s;

    -- Города из ref_city
    INSERT INTO core.city (city_id, city_name)
    SELECT row_number() OVER (ORDER BY c.city_norm), c.city_name
      FROM core.ref_city c;

    -- Люди из ref_person, ФИО через initcap
    INSERT INTO core.person (person_id, person_code, last_name, first_name, patronymic, city_id)
    SELECT p.person_no,
           lpad(p.person_no::text, greatest(3, length(p.person_no::text)), '0'),
           initcap(p.last_name),
           initcap(p.first_name),
           initcap(nullif(p.patronymic, '')),
           c.city_id
      FROM core.ref_person p
      JOIN core.city c ON c.city_name = p.city_name;

    -- Маршруты из строк LOAD
    INSERT INTO core.route (route_id, from_city_id, to_city_id)
    SELECT row_number() OVER (ORDER BY fc.city_id, tc.city_id), fc.city_id, tc.city_id
      FROM (SELECT DISTINCT route_from, route_to
              FROM core.stg_event_clean
             WHERE outcome = 'LOAD') s
      JOIN core.city fc ON fc.city_name = s.route_from
      JOIN core.city tc ON tc.city_name = s.route_to;

    -- Посылки из строк LOAD, курьер из любого события
    INSERT INTO core.shipment (shipment_id, sender_person_id, receiver_person_id, courier_person_id, route_id)
    SELECT s.shipment_id, s.sender_no, s.receiver_no, s.courier_no, r.route_id
      FROM (SELECT shipment_id,
                   max(sender_no)   AS sender_no,
                   max(receiver_no) AS receiver_no,
                   max(courier_no)  AS courier_no,
                   max(route_from)  AS route_from,
                   max(route_to)    AS route_to
              FROM core.stg_event_clean
             WHERE outcome = 'LOAD'
             GROUP BY shipment_id) s
      JOIN core.city  fc ON fc.city_name = s.route_from
      JOIN core.city  tc ON tc.city_name = s.route_to
      JOIN core.route r  ON r.from_city_id = fc.city_id AND r.to_city_id = tc.city_id
     WHERE s.sender_no IS NOT NULL
       AND s.receiver_no IS NOT NULL;

    -- События: одна строка LOAD = одно событие
    INSERT INTO core.shipment_event (event_id, shipment_id, event_datetime, status_id, raw_hash)
    SELECT row_number() OVER (ORDER BY e.shipment_id, e.event_ts, e.status_seq, e.raw_row_id),
           e.shipment_id, e.event_ts, e.status_seq, e.raw_row_id
      FROM core.stg_event_clean e
      JOIN core.shipment sh ON sh.shipment_id = e.shipment_id
     WHERE e.outcome = 'LOAD';

    -- Флаги событий
    INSERT INTO core.event_quality_flag (event_id, flag_code)
    SELECT DISTINCT ev.event_id, f.flag
      FROM core.shipment_event ev
      JOIN core.stg_event_clean e ON e.raw_row_id = ev.raw_hash
     CROSS JOIN LATERAL unnest(e.flags) AS f(flag)
      JOIN core.ref_quality_flag q ON q.flag_code = f.flag AND q.flag_level = 'EVENT';

    -- Флаги посылок
    INSERT INTO core.shipment_quality_flag (shipment_id, flag_code)
    SELECT DISTINCT e.shipment_id, f.flag
      FROM core.stg_event_clean e
      JOIN core.shipment sh ON sh.shipment_id = e.shipment_id
     CROSS JOIN LATERAL unnest(e.flags) AS f(flag)
      JOIN core.ref_quality_flag q ON q.flag_code = f.flag AND q.flag_level = 'SHIPMENT'
     WHERE e.outcome = 'LOAD'
    UNION
    SELECT sh.shipment_id, 'NO_COURIER'
      FROM core.shipment sh
     WHERE sh.courier_person_id IS NULL
    UNION
    SELECT ev.shipment_id, 'INCOMPLETE_CHAIN'
      FROM core.shipment_event ev
      JOIN core.event_status st ON st.status_id = ev.status_id AND NOT st.is_terminal
     GROUP BY ev.shipment_id
    HAVING count(DISTINCT ev.status_id) < (SELECT count(*) FROM core.event_status WHERE NOT is_terminal);
END;
$$;
