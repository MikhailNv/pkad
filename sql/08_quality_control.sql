-- Этап 8. Проверки качества — шаг 07

SET search_path = core, public;

-- Журнал запусков (etl_run_log другой структуры пересоздаётся, если пуст)
DO $$
BEGIN
    IF to_regclass('core.etl_run_log') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'core' AND table_name = 'etl_run_log' AND column_name = 'raw_fingerprint') THEN
        IF EXISTS (SELECT 1 FROM core.etl_run_log) THEN
            RAISE EXCEPTION 'core.etl_run_log старой структуры содержит данные — перенесите их вручную';
        END IF;
        DROP TABLE core.etl_run_log CASCADE;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS core.etl_run_log (
    run_id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at         timestamptz NOT NULL,
    finished_at        timestamptz,
    status             text NOT NULL CHECK (status IN ('RUNNING', 'SUCCESS', 'CHECKS_FAILED')),
    raw_rows           int,
    rows_loaded        int,
    rows_quarantined   int,
    rows_duplicated    int,
    rows_unaccounted   int,
    checks_failed      int,          -- ошибок ERROR
    checks_warned      int,          -- предупреждений
    raw_fingerprint    text NOT NULL -- md5 RAW на старте
);

CREATE TABLE IF NOT EXISTS core.run_step_log (
    run_id     bigint NOT NULL REFERENCES core.etl_run_log ON DELETE CASCADE,
    step_no    int    NOT NULL,
    step_name  text   NOT NULL,
    result     text,
    seconds    numeric(10,3) NOT NULL,
    PRIMARY KEY (run_id, step_no)
);

CREATE TABLE IF NOT EXISTS core.dq_check_result (
    run_id       bigint NOT NULL REFERENCES core.etl_run_log ON DELETE CASCADE,
    check_no     int    NOT NULL,
    check_name   text   NOT NULL,
    check_level  text   NOT NULL CHECK (check_level IN ('ERROR', 'WARNING')),
    description  text   NOT NULL,
    violations   bigint NOT NULL,
    passed       boolean NOT NULL,
    PRIMARY KEY (run_id, check_no)
);

CREATE TABLE IF NOT EXISTS core.run_metric (
    run_id       bigint NOT NULL REFERENCES core.etl_run_log ON DELETE CASCADE,
    metric_name  text   NOT NULL,
    metric_value text   NOT NULL,
    PRIMARY KEY (run_id, metric_name)
);

-- Отпечаток RAW
CREATE OR REPLACE FUNCTION core.fn_raw_fingerprint()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT count(*) || ':' || md5(coalesce(string_agg(h, '' ORDER BY h), ''))
      FROM (SELECT md5(r::text) AS h FROM public.raw_data_06 r) x;
$$;

-- Отпечаток таблицы
CREATE OR REPLACE FUNCTION core.fn_table_fingerprint(p_table regclass)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
    EXECUTE format('SELECT count(*) || '':'' || md5(coalesce(string_agg(t::text, ''|'' ORDER BY t::text), '''')) FROM %s t',
                   p_table)
       INTO v;
    RETURN v;
END $$;

-- Шаг 07: возвращает число ошибок ERROR
CREATE OR REPLACE FUNCTION core.step_07_quality_checks(p_run_id bigint)
RETURNS int
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_raw_before text;
    v_raw_after  text;
    v_failed     int;
    t            text;
BEGIN
    SELECT raw_fingerprint INTO v_raw_before FROM core.etl_run_log WHERE run_id = p_run_id;
    v_raw_after := core.fn_raw_fingerprint();

    DELETE FROM core.dq_check_result WHERE run_id = p_run_id;
    DELETE FROM core.run_metric      WHERE run_id = p_run_id;

    CREATE TEMP TABLE IF NOT EXISTS tmp_raw_ids (raw_row_id text PRIMARY KEY) ON COMMIT DROP;
    TRUNCATE tmp_raw_ids;
    -- raw_row_id текущего RAW
    INSERT INTO tmp_raw_ids
    SELECT raw_hash || ':' || row_number() OVER (PARTITION BY raw_hash)
      FROM (SELECT core.fn_raw_hash(shipment_id, event_datetime, sender_info, receiver_info,
                                    route_info, courier_info, status_info) AS raw_hash
              FROM public.raw_data_06) h;

    INSERT INTO core.dq_check_result (run_id, check_no, check_name, check_level, description, violations, passed)
    SELECT p_run_id, c.no, c.name, c.lvl, c.descr, c.v, c.v = 0
      FROM (VALUES
        -- RAW и итоги строк
        (1, 'RAW_UNCHANGED', 'ERROR', 'RAW не изменился за время запуска (отпечаток до = после)',
            (v_raw_before IS DISTINCT FROM v_raw_after)::int::bigint),
        (2, 'RAW_UNACCOUNTED', 'ERROR', 'Строки RAW без итога (LOAD / QUARANTINE / DUPLICATE)',
            (SELECT count(*) FROM tmp_raw_ids i
              WHERE NOT EXISTS (SELECT 1 FROM core.raw_row_outcome o WHERE o.raw_row_id = i.raw_row_id))),
        (3, 'RAW_STALE_OUTCOME', 'ERROR', 'Итоги для строк, которых нет в текущем RAW',
            (SELECT count(*) FROM core.raw_row_outcome o
              WHERE NOT EXISTS (SELECT 1 FROM tmp_raw_ids i WHERE i.raw_row_id = o.raw_row_id))),
        (4, 'RAW_BALANCE', 'ERROR', 'Исходных ≠ загружено + карантин + дубли + неучтённые',
            (SELECT abs((SELECT count(*) FROM tmp_raw_ids) - count(*)) FROM core.raw_row_outcome)),
        (5, 'QUARANTINE_OUTCOME_MISMATCH', 'ERROR', 'Активный карантин не совпадает с итогом QUARANTINE',
            (SELECT count(*) FROM (SELECT raw_row_id FROM core.quarantine WHERE is_active
                                   EXCEPT SELECT raw_row_id FROM core.raw_row_outcome WHERE outcome = 'QUARANTINE') a)
          + (SELECT count(*) FROM (SELECT raw_row_id FROM core.raw_row_outcome WHERE outcome = 'QUARANTINE'
                                   EXCEPT SELECT raw_row_id FROM core.quarantine WHERE is_active) b)),
        (6, 'DUPLICATE_ORIGIN_INVALID', 'ERROR', 'Дубль ссылается на несуществующий оригинал или на другой дубль',
            (SELECT count(*) FROM core.stg_event_clean d
               LEFT JOIN core.stg_event_clean o ON o.raw_row_id = d.duplicate_of
              WHERE d.outcome = 'DUPLICATE' AND (o.raw_row_id IS NULL OR o.outcome = 'DUPLICATE'))),
        (7, 'QUARANTINE_REASON_UNKNOWN', 'ERROR', 'Причина карантина не из справочника ref_quarantine_reason',
            (SELECT count(*) FROM core.quarantine q, unnest(q.reason_codes) r
              WHERE q.is_active AND r NOT IN (SELECT reason_code FROM core.ref_quarantine_reason))),
        (8, 'QUARANTINE_NO_SOURCE', 'ERROR', 'Запись карантина без исходной строки RAW (payload)',
            (SELECT count(*) FROM core.quarantine WHERE is_active AND (payload IS NULL OR payload = '{}'::jsonb))),
        -- Строки LOAD
        (9, 'LOAD_ROW_MISSING_FIELDS', 'ERROR', 'Загружаемая строка без обязательных полей',
            (SELECT count(*) FROM core.stg_event_clean
              WHERE outcome = 'LOAD' AND (shipment_id IS NULL OR event_ts IS NULL OR status_seq IS NULL
                                          OR route_from IS NULL OR route_to IS NULL))),
        (10, 'LOAD_EVENT_KEY_DUPLICATE', 'ERROR', 'Повтор ключа события (посылка, время, этап) среди загружаемых',
            (SELECT count(*) - count(DISTINCT (shipment_id, event_ts, status_code))
               FROM core.stg_event_clean WHERE outcome = 'LOAD')),
        (11, 'LOAD_ROW_NOT_IN_CORE', 'ERROR', 'Строка с итогом LOAD не дала событие в core (молчаливая потеря)',
            (SELECT count(*) FROM core.raw_row_outcome o
              WHERE o.outcome = 'LOAD'
                AND NOT EXISTS (SELECT 1 FROM core.shipment_event e WHERE e.raw_hash = o.raw_row_id))),
        (12, 'CORE_EVENT_NOT_LOAD', 'ERROR', 'Событие core из строки, которая не LOAD (категории пересекаются)',
            (SELECT count(*) FROM core.shipment_event e
               LEFT JOIN core.raw_row_outcome o ON o.raw_row_id = e.raw_hash
              WHERE o.outcome IS DISTINCT FROM 'LOAD')),
        (13, 'CORE_EVENT_RAW_REUSED', 'ERROR', 'Одна строка RAW дала больше одного события',
            (SELECT count(raw_hash) - count(DISTINCT raw_hash) FROM core.shipment_event)),
        -- Целостность core
        (14, 'SHIPMENT_WITHOUT_EVENTS', 'ERROR', 'Посылка без событий',
            (SELECT count(*) FROM core.shipment s
              WHERE NOT EXISTS (SELECT 1 FROM core.shipment_event e WHERE e.shipment_id = s.shipment_id))),
        (15, 'SHIPMENT_PARTY_INCONSISTENT', 'ERROR', 'Разные отправитель/получатель/курьер/маршрут в загружаемых строках одной посылки',
            (SELECT count(*) FROM (SELECT shipment_id FROM core.stg_event_clean WHERE outcome = 'LOAD'
                                    GROUP BY shipment_id
                                   HAVING count(DISTINCT sender_no) > 1 OR count(DISTINCT receiver_no) > 1
                                       OR count(DISTINCT courier_no) > 1
                                       OR count(DISTINCT (route_from, route_to)) > 1) x)),
        (16, 'EVENT_ORDER_VIOLATION', 'ERROR', 'Более поздний этап посылки раньше или одновременно с более ранним',
            (SELECT count(*) FROM core.shipment_event a
               JOIN core.shipment_event b ON b.shipment_id = a.shipment_id
                                         AND a.status_id < b.status_id
                                         AND a.event_datetime >= b.event_datetime)),
        (17, 'FLAG_CODE_UNKNOWN', 'ERROR', 'Флаг качества не из справочника ref_quality_flag',
            (SELECT count(*) FROM (SELECT flag_code FROM core.event_quality_flag
                                   UNION ALL SELECT flag_code FROM core.shipment_quality_flag) f
              WHERE f.flag_code NOT IN (SELECT flag_code FROM core.ref_quality_flag))),
        (18, 'CORE_COUNTS_MISMATCH', 'ERROR', 'Сверка количеств core.check_core_counts(): есть расхождения',
            (SELECT count(*) FROM core.check_core_counts() WHERE NOT is_equal)),
        -- Витрины
        (19, 'MART_SHIPMENT_RECONCILE', 'ERROR', 'mart_shipment ≠ core: число посылок или событий',
            (SELECT abs((SELECT count(*) FROM core.mart_shipment) - (SELECT count(*) FROM core.shipment))
                  + abs((SELECT coalesce(sum(events_loaded), 0) FROM core.mart_shipment)
                        - (SELECT count(*) FROM core.shipment_event)))),
        (20, 'MART_ROUTE_DAILY_RECONCILE', 'ERROR', 'mart_route_daily: сумма посылок ≠ core.shipment',
            (SELECT abs((SELECT coalesce(sum(shipments), 0) FROM core.mart_route_daily)
                        - (SELECT count(*) FROM core.shipment)))),
        (21, 'MART_COURIER_DAILY_RECONCILE', 'ERROR', 'mart_courier_daily: сумма посылок ≠ посылкам с курьером',
            (SELECT abs((SELECT coalesce(sum(shipments), 0) FROM core.mart_courier_daily)
                        - (SELECT count(*) FROM core.shipment WHERE courier_person_id IS NOT NULL)))),
        (22, 'MART_EVENT_DAILY_RECONCILE', 'ERROR', 'mart_event_daily: сумма событий ≠ core.shipment_event',
            (SELECT abs((SELECT coalesce(sum(events), 0) FROM core.mart_event_daily)
                        - (SELECT count(*) FROM core.shipment_event)))),
        -- Предупреждения
        (23, 'SHIPMENT_NO_COURIER', 'WARNING', 'Посылка без курьера (ни в одном загруженном событии курьер не указан)',
            (SELECT count(*) FROM core.shipment WHERE courier_person_id IS NULL)),
        (24, 'SHIPMENT_INCOMPLETE_CHAIN', 'WARNING', 'Посылка без части базовых этапов (строки в карантине)',
            (SELECT count(*) FROM core.shipment_quality_flag WHERE flag_code = 'INCOMPLETE_CHAIN')),
        (25, 'QUARANTINE_QUEUE_NEW', 'WARNING', 'Записи карантина, ожидающие ручной обработки (NEW)',
            (SELECT count(*) FROM core.quarantine WHERE is_active AND resolution_status = 'NEW'))
      ) AS c(no, name, lvl, descr, v);

    -- Показатели запуска
    INSERT INTO core.run_metric (run_id, metric_name, metric_value)
    SELECT p_run_id, m, v FROM (VALUES
        ('raw.fingerprint_before', v_raw_before),
        ('raw.fingerprint_after',  v_raw_after),
        ('raw.rows',               (SELECT count(*) FROM tmp_raw_ids)::text),
        ('outcome.load',           (SELECT count(*) FROM core.raw_row_outcome WHERE outcome = 'LOAD')::text),
        ('outcome.quarantine',     (SELECT count(*) FROM core.raw_row_outcome WHERE outcome = 'QUARANTINE')::text),
        ('outcome.duplicate',      (SELECT count(*) FROM core.raw_row_outcome WHERE outcome = 'DUPLICATE')::text),
        ('quarantine.active',      (SELECT count(*) FROM core.quarantine WHERE is_active)::text),
        -- без отметок времени
        ('quarantine.fingerprint', (SELECT count(*) || ':' || md5(coalesce(string_agg(
                                        concat_ws('|', raw_row_id, primary_reason, reason_codes::text, reason_detail,
                                                  payload::text, suggested_fix::text, is_active, resolution_status),
                                        '#' ORDER BY raw_row_id), ''))
                                      FROM core.quarantine)),
        ('sum.mart_shipment.lead_time_hours', (SELECT coalesce(sum(lead_time_hours), 0) FROM core.mart_shipment)::text),
        ('sum.mart_shipment.events_loaded',   (SELECT coalesce(sum(events_loaded), 0) FROM core.mart_shipment)::text),
        ('sum.mart_route_daily.shipments',    (SELECT coalesce(sum(shipments), 0) FROM core.mart_route_daily)::text),
        ('sum.mart_courier_daily.shipments',  (SELECT coalesce(sum(shipments), 0) FROM core.mart_courier_daily)::text),
        ('sum.shipment_event.event_id',       (SELECT coalesce(sum(event_id), 0) FROM core.shipment_event)::text)
    ) x(m, v);

    FOREACH t IN ARRAY ARRAY[
        'ref_city', 'ref_person', 'stg_raw_row', 'stg_event_clean', 'raw_row_outcome',
        'city', 'person', 'route', 'event_status', 'shipment', 'shipment_event',
        'event_quality_flag', 'shipment_quality_flag',
        'mart_shipment', 'mart_route_daily', 'mart_courier_daily', 'mart_event_daily']
    LOOP
        EXECUTE format('INSERT INTO core.run_metric (run_id, metric_name, metric_value)
                        SELECT $1, $2, count(*)::text FROM core.%I', t)
          USING p_run_id, 'rows.' || t;
        INSERT INTO core.run_metric (run_id, metric_name, metric_value)
        VALUES (p_run_id, 'fingerprint.' || t, core.fn_table_fingerprint(('core.' || t)::regclass));
    END LOOP;

    SELECT count(*) INTO v_failed FROM core.dq_check_result
     WHERE run_id = p_run_id AND check_level = 'ERROR' AND NOT passed;
    RETURN v_failed;
END;
$$;

-- Представления контроля
CREATE OR REPLACE VIEW core.v_run_history AS
SELECT l.run_id, l.started_at, l.finished_at,
       round(extract(epoch FROM l.finished_at - l.started_at)::numeric, 1) AS seconds,
       l.status, l.raw_rows, l.rows_loaded, l.rows_quarantined, l.rows_duplicated, l.rows_unaccounted,
       l.raw_rows = l.rows_loaded + l.rows_quarantined + l.rows_duplicated + l.rows_unaccounted AS balance_ok,
       l.checks_failed, l.checks_warned
  FROM core.etl_run_log l
 ORDER BY l.run_id;

-- Сравнение двух последних запусков
CREATE OR REPLACE VIEW core.v_run_comparison AS
WITH r AS (
    SELECT run_id, row_number() OVER (ORDER BY run_id DESC) AS rn
      FROM core.etl_run_log WHERE status <> 'RUNNING'
),
prev AS (SELECT m.* FROM core.run_metric m JOIN r ON r.run_id = m.run_id AND r.rn = 2),
last AS (SELECT m.* FROM core.run_metric m JOIN r ON r.run_id = m.run_id AND r.rn = 1)
SELECT coalesce(l.metric_name, p.metric_name) AS metric_name,
       p.run_id       AS prev_run_id,
       p.metric_value AS prev_value,
       l.run_id       AS last_run_id,
       l.metric_value AS last_value,
       p.metric_value IS NOT DISTINCT FROM l.metric_value AS is_same
  FROM last l
  FULL JOIN prev p ON p.metric_name = l.metric_name
 ORDER BY 1;

CREATE OR REPLACE VIEW core.v_dq_last_run AS
SELECT d.run_id, d.check_no, d.check_name, d.check_level, d.description, d.violations, d.passed
  FROM core.dq_check_result d
 WHERE d.run_id = (SELECT max(run_id) FROM core.etl_run_log WHERE status <> 'RUNNING')
 ORDER BY d.check_no;

-- Статистика RAW
CREATE OR REPLACE VIEW core.v_raw_processing_stats AS
WITH cur AS (
    SELECT raw_hash || ':' || row_number() OVER (PARTITION BY raw_hash) AS raw_row_id
      FROM (SELECT core.fn_raw_hash(shipment_id, event_datetime, sender_info, receiver_info,
                                    route_info, courier_info, status_info) AS raw_hash
              FROM public.raw_data_06) h
),
x AS (
    SELECT c.raw_row_id, coalesce(o.outcome, 'UNACCOUNTED') AS outcome
      FROM cur c LEFT JOIN core.raw_row_outcome o ON o.raw_row_id = c.raw_row_id
)
SELECT count(*)                                           AS raw_total,
       count(*) FILTER (WHERE outcome = 'LOAD')           AS loaded,
       count(*) FILTER (WHERE outcome = 'QUARANTINE')     AS quarantined,
       count(*) FILTER (WHERE outcome = 'DUPLICATE')      AS duplicates,
       count(*) FILTER (WHERE outcome = 'UNACCOUNTED')    AS unaccounted,
       count(*) = count(*) FILTER (WHERE outcome = 'LOAD')
                + count(*) FILTER (WHERE outcome = 'QUARANTINE')
                + count(*) FILTER (WHERE outcome = 'DUPLICATE')
                + count(*) FILTER (WHERE outcome = 'UNACCOUNTED') AS balance_ok,
       (SELECT count(*) FROM core.shipment_event)         AS core_events
  FROM x;

-- Итог строк RAW по причинам
CREATE OR REPLACE VIEW core.v_raw_outcome_breakdown AS
SELECT o.outcome,
       CASE o.outcome WHEN 'QUARANTINE' THEN q.primary_reason
                      WHEN 'DUPLICATE'  THEN 'EXACT_DUPLICATE'
                      ELSE 'LOADED' END                    AS reason,
       r.description,
       count(*)                                            AS raw_rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)  AS pct
  FROM core.raw_row_outcome o
  LEFT JOIN core.quarantine q            ON q.raw_row_id = o.raw_row_id AND o.outcome = 'QUARANTINE'
  LEFT JOIN core.ref_quarantine_reason r ON r.reason_code = q.primary_reason
 GROUP BY o.outcome, 2, r.description, r.priority
 ORDER BY CASE o.outcome WHEN 'LOAD' THEN 1 WHEN 'QUARANTINE' THEN 2 ELSE 3 END, r.priority NULLS FIRST;
