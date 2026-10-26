-- =====================================================================
-- Этапы 5–6. Снимок RAW, очищенные события, карантин, итог по каждой строке RAW
-- Команда 06 · «Доставка посылок»
--
-- Порядок запуска:
--   fn_build_refs()          — справочники городов и людей из RAW (01_parse_functions.sql)
--   step_02_stage_raw()      — снимок RAW со стабильным raw_row_id, точные дубли
--   step_04_clean_events()   — разбор полей + проверки на уровне записи → issues / flags / outcome
--   step_05_quarantine()     — карантин (upsert, ручная обработка сохраняется) + итог по строкам RAW
--   run_stage_5_6()          — всё по порядку
--
-- Категории итога не пересекаются, приоритет: DUPLICATE → QUARANTINE → LOAD.
-- LOAD — строка корректна и загружается в core этапом 7.
-- =====================================================================

SET search_path = core, public;

-- ---------------------------------------------------------------------
-- Настройки
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref_setting (
    name  text PRIMARY KEY,
    value text NOT NULL,
    note  text
);
INSERT INTO ref_setting VALUES
    ('period_from', '2026-01-01', 'начало отчётного периода (включительно)'),
    ('period_to',   '2026-12-31', 'конец отчётного периода (включительно)'),
    ('event_step',  '8 hours',    'шаг между этапами посылки — только для подсказок в карантине')
ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value, note = EXCLUDED.note;

-- ---------------------------------------------------------------------
-- Справочник причин карантина
-- priority: чем меньше, тем важнее (главная причина записи)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref_quarantine_reason (
    reason_code   text PRIMARY KEY,
    priority      smallint NOT NULL,
    description   text NOT NULL,
    manual_action text NOT NULL
);
TRUNCATE ref_quarantine_reason;
INSERT INTO ref_quarantine_reason VALUES
    ('ID_EMPTY',                  10, 'Нет идентификатора посылки',                         'Найти посылку по участникам и времени'),
    ('ID_INVALID',                11, 'Идентификатор посылки не по формату PKG-NNNNNN',      'Уточнить номер посылки'),
    ('EVENT_KEY_CONFLICT',        15, 'Одно событие (посылка, время, статус) с разными данными', 'Выбрать верную запись'),
    ('SHIPMENT_PARTY_CONFLICT',   16, 'Отправитель или получатель различается внутри посылки', 'Определить верного участника'),
    ('SHIPMENT_COURIER_CONFLICT', 17, 'Курьер различается внутри посылки',                   'Определить курьера'),
    ('DT_EMPTY',                  20, 'Дата и время не заполнены',                           'Восстановить время события'),
    ('DT_PLACEHOLDER',            21, 'Заглушка вместо даты (NULL, «неизвестно»)',           'Восстановить время события'),
    ('DT_RELATIVE',               22, 'Относительная дата без точки отсчёта («сегодня утром»)', 'Восстановить время события'),
    ('DT_UNKNOWN_FORMAT',         23, 'Нераспознанный формат даты',                          'Привести дату к формату'),
    ('DT_NO_TIME',                24, 'Дата без времени',                                    'Уточнить время'),
    ('DT_INVALID_DATE',           25, 'Несуществующая дата (31.02 и т.п.)',                  'Уточнить дату у источника'),
    ('DT_INVALID_TIME',           26, 'Несуществующее время (25:61 и т.п.)',                 'Уточнить время у источника'),
    ('DT_OUT_OF_PERIOD',          27, 'Дата вне отчётного периода',                          'Проверить год и месяц'),
    ('STATUS_EMPTY',              30, 'Статус не заполнен',                                  'Определить статус'),
    ('STATUS_PLACEHOLDER',        31, 'Заглушка вместо статуса (???)',                       'Определить статус'),
    ('STATUS_UNKNOWN',            32, 'Статус не из справочника',                            'Сопоставить со справочником'),
    ('STATUS_MISLABELED',         33, '«Доставлено» стоит вместо одного из базовых этапов',  'Определить фактический этап'),
    ('STATUS_ORDER_CONFLICT',     34, 'Этап раньше по времени, чем предыдущий этап',         'Проверить время и статус'),
    ('ROUTE_EMPTY',               40, 'Маршрут не заполнен',                                 'Восстановить маршрут'),
    ('ROUTE_FORMAT',              41, 'Нераспознанный формат маршрута',                      'Привести маршрут к формату'),
    ('ROUTE_CITY_UNKNOWN',        42, 'Город маршрута не из справочника',                    'Сопоставить город'),
    ('ROUTE_MISMATCH',            43, 'Маршрут не совпадает с городами участников',          'Разобрать противоречие');
-- причины по участникам: SENDER_*, RECEIVER_*, COURIER_*
INSERT INTO ref_quarantine_reason
SELECT r.prefix || '_' || e.code, r.base + e.shift, r.who || ': ' || e.descr, e.action
  FROM (VALUES ('SENDER', 50, 'Отправитель'), ('RECEIVER', 60, 'Получатель'), ('COURIER', 70, 'Курьер')) r(prefix, base, who)
 CROSS JOIN (VALUES
    ('UNKNOWN',       0, 'ФИО не распознано или человека нет в справочнике', 'Сопоставить человека'),
    ('INVALID',       1, 'посторонние символы в ФИО',                        'Исправить ФИО'),
    ('AMBIGUOUS',     2, 'ФИО подходит нескольким людям',                    'Выбрать человека'),
    ('CODE_ONLY',     3, 'указан только код, ФИО нет',                       'Восстановить ФИО по коду'),
    ('CODE_CONFLICT', 4, 'код не совпадает с ФИО',                           'Проверить код и ФИО'),
    ('ROLE_MISMATCH', 5, 'код другой роли (S/R/C)',                          'Проверить поле'),
    ('CITY_EMPTY',    6, 'город не указан',                                  'Восстановить город'),
    ('CITY_UNKNOWN',  7, 'город не из справочника',                          'Сопоставить город'),
    ('CITY_MISMATCH', 8, 'город не совпадает с городом человека',            'Проверить человека и город')
 ) e(code, shift, descr, action)
 WHERE NOT (r.prefix = 'COURIER' AND e.code LIKE 'CITY%');

-- ---------------------------------------------------------------------
-- Хеш строки RAW: md5 от записи из 7 полей (NULL и '' различаются)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_raw_hash(a text, b text, c text, d text, e text, f text, g text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT md5(row(a, b, c, d, e, f, g)::text)
$$;

-- Есть ли среди причин проблема с датой (такие строки не участвуют в проверках по времени)
CREATE OR REPLACE FUNCTION fn_has_dt_issue(issues text[])
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT EXISTS (SELECT 1 FROM unnest(issues) i WHERE i LIKE 'DT\_%')
$$;

-- ---------------------------------------------------------------------
-- Снимок RAW
-- raw_row_id = md5(7 полей) || ':' || номер вхождения. Точные дубли побайтово
-- одинаковы, поэтому нумерация внутри группы не зависит от физического порядка.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_raw_row (
    raw_row_id         text PRIMARY KEY,
    raw_hash           text NOT NULL,
    occurrence         int  NOT NULL,
    is_exact_duplicate boolean NOT NULL,
    shipment_id        text,
    event_datetime     text,
    sender_info        text,
    receiver_info      text,
    route_info         text,
    courier_info       text,
    status_info        text
);

CREATE OR REPLACE FUNCTION step_02_stage_raw()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    TRUNCATE core.stg_event_clean, core.stg_raw_row;
    INSERT INTO core.stg_raw_row
    SELECT raw_hash || ':' || occurrence, raw_hash, occurrence, occurrence > 1,
           shipment_id, event_datetime, sender_info, receiver_info, route_info, courier_info, status_info
      FROM (
        SELECT h.*, row_number() OVER (PARTITION BY h.raw_hash) AS occurrence
          FROM (SELECT r.*,
                       core.fn_raw_hash(r.shipment_id, r.event_datetime, r.sender_info, r.receiver_info,
                                               r.route_info, r.courier_info, r.status_info) AS raw_hash
                  FROM public.raw_data_06 r) h
      ) x;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Очищенные события: разобранные поля + причины карантина + флаги качества
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_event_clean (
    raw_row_id         text PRIMARY KEY REFERENCES stg_raw_row,
    is_exact_duplicate boolean NOT NULL,
    duplicate_of       text,                 -- raw_row_id оригинала для дублей
    shipment_id        text,
    event_ts           timestamp,
    status_code        text,
    status_seq         smallint,
    sender_no          int,
    sender_city        text,
    receiver_no        int,
    receiver_city      text,
    courier_no         int,
    route_from         text,
    route_to           text,
    issues             text[] NOT NULL DEFAULT '{}',   -- причины карантина
    flags              text[] NOT NULL DEFAULT '{}',   -- флаги качества (строка загружается)
    outcome            text CHECK (outcome IN ('LOAD', 'QUARANTINE', 'DUPLICATE'))
);

CREATE OR REPLACE FUNCTION step_04_clean_events()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_from date := (SELECT value::date FROM core.ref_setting WHERE name = 'period_from');
    v_to   date := (SELECT value::date FROM core.ref_setting WHERE name = 'period_to');
    n int;
BEGIN
    TRUNCATE core.stg_event_clean;

    -- 1) разбор полей: каждая функция вызывается один раз на строку
    INSERT INTO core.stg_event_clean
        (raw_row_id, is_exact_duplicate, duplicate_of, shipment_id, event_ts, status_code, status_seq,
         sender_no, sender_city, receiver_no, receiver_city, courier_no, route_from, route_to, issues, flags)
    SELECT r.raw_row_id, r.is_exact_duplicate,
           CASE WHEN r.is_exact_duplicate THEN r.raw_hash || ':1' END,
           id.shipment_id, ts.ts, st.status_code, rs.seq_no,
           sp.person_no, sc.city_name, rp.person_no, rc.city_name, cp.person_no,
           rt.from_city, rt.to_city,
           array_remove(ARRAY[
               id.err, ts.err,
               CASE WHEN ts.ts::date NOT BETWEEN v_from AND v_to THEN 'DT_OUT_OF_PERIOD' END,
               st.err, rt.err,
               'SENDER_'   || nullif(replace(sp.err, 'PERSON_', ''), 'EMPTY'),
               'SENDER_'   || sc.err,
               'RECEIVER_' || nullif(replace(rp.err, 'PERSON_', ''), 'EMPTY'),
               'RECEIVER_' || rc.err,
               'COURIER_'  || nullif(replace(cp.err, 'PERSON_', ''), 'EMPTY')
           ], NULL),
           array_remove(ARRAY[
               CASE WHEN sp.err = 'PERSON_EMPTY' THEN 'SENDER_EMPTY' END,
               CASE WHEN rp.err = 'PERSON_EMPTY' THEN 'RECEIVER_EMPTY' END,
               CASE WHEN st.status_code = 'HANDED_TO_COURIER' AND cp.err = 'PERSON_EMPTY'
                    THEN 'COURIER_MISSING_ON_HANDOVER' END,
               CASE WHEN sp.person_no = rp.person_no THEN 'SELF_SHIPMENT' END,
               CASE WHEN sc.city_name = rc.city_name THEN 'SAME_CITY_DELIVERY' END
           ], NULL)
      FROM core.stg_raw_row r
      CROSS JOIN LATERAL core.fn_parse_shipment_id(r.shipment_id) id
      CROSS JOIN LATERAL core.fn_parse_ts(r.event_datetime) ts
      CROSS JOIN LATERAL core.fn_parse_status(r.status_info) st
      CROSS JOIN LATERAL core.fn_parse_route(r.route_info) rt
      CROSS JOIN LATERAL core.fn_split_party(r.sender_info) s
      CROSS JOIN LATERAL core.fn_parse_person(s.name_part, 'S') sp
      CROSS JOIN LATERAL core.fn_parse_city(s.city_part) sc
      CROSS JOIN LATERAL core.fn_split_party(r.receiver_info) rv
      CROSS JOIN LATERAL core.fn_parse_person(rv.name_part, 'R') rp
      CROSS JOIN LATERAL core.fn_parse_city(rv.city_part) rc
      CROSS JOIN LATERAL core.fn_parse_person(r.courier_info, 'C') cp
      LEFT JOIN core.ref_status rs ON rs.status_code = st.status_code;
    GET DIAGNOSTICS n = ROW_COUNT;

    -- 2) проверки на уровне записи и посылки (точные дубли не участвуют — это копии)

    -- маршрут должен совпадать с городами участников
    UPDATE core.stg_event_clean
       SET issues = issues || 'ROUTE_MISMATCH'::text
     WHERE NOT is_exact_duplicate
       AND route_from IS NOT NULL AND sender_city IS NOT NULL AND receiver_city IS NOT NULL
       AND (route_from <> sender_city OR route_to <> receiver_city);

    -- город в строке должен совпадать с городом человека
    UPDATE core.stg_event_clean e
       SET issues = issues || 'SENDER_CITY_MISMATCH'::text
      FROM core.ref_person p
     WHERE NOT e.is_exact_duplicate AND p.person_no = e.sender_no
       AND e.sender_city IS NOT NULL AND e.sender_city IS DISTINCT FROM p.city_name;
    UPDATE core.stg_event_clean e
       SET issues = issues || 'RECEIVER_CITY_MISMATCH'::text
      FROM core.ref_person p
     WHERE NOT e.is_exact_duplicate AND p.person_no = e.receiver_no
       AND e.receiver_city IS NOT NULL AND e.receiver_city IS DISTINCT FROM p.city_name;

    -- участники и курьер не должны меняться внутри посылки; при конфликте личность
    -- участника посылки не определена, поэтому в карантин идут все её строки
    UPDATE core.stg_event_clean e
       SET issues = e.issues || 'SHIPMENT_PARTY_CONFLICT'::text
      FROM (SELECT shipment_id FROM core.stg_event_clean
             WHERE NOT is_exact_duplicate AND shipment_id IS NOT NULL
             GROUP BY shipment_id
            HAVING count(DISTINCT sender_no) > 1 OR count(DISTINCT receiver_no) > 1) s
     WHERE NOT e.is_exact_duplicate AND e.shipment_id = s.shipment_id;
    UPDATE core.stg_event_clean e
       SET issues = e.issues || 'SHIPMENT_COURIER_CONFLICT'::text
      FROM (SELECT shipment_id FROM core.stg_event_clean
             WHERE NOT is_exact_duplicate AND shipment_id IS NOT NULL
             GROUP BY shipment_id
            HAVING count(DISTINCT courier_no) > 1) s
     WHERE NOT e.is_exact_duplicate AND e.shipment_id = s.shipment_id;

    -- «Доставлено» допустимо, только если у посылки есть все 5 базовых этапов
    -- и оно позже последнего из них. Допущение: этап, пришедший как «???», не засчитывается,
    -- поэтому настоящее «Доставлено» в такой посылке тоже уйдёт в карантин (лучше, чем угадать).
    -- Время последнего этапа берём только по строкам без проблем с датой.
    UPDATE core.stg_event_clean e
       SET issues = e.issues || 'STATUS_MISLABELED'::text
      FROM (SELECT shipment_id,
                   count(DISTINCT status_seq) FILTER (WHERE status_seq BETWEEN 1 AND 5) AS n_base,
                   max(event_ts) FILTER (WHERE status_seq BETWEEN 1 AND 5
                                           AND NOT core.fn_has_dt_issue(issues))  AS last_base_ts
              FROM core.stg_event_clean
             WHERE NOT is_exact_duplicate AND shipment_id IS NOT NULL
             GROUP BY shipment_id) s
     WHERE NOT e.is_exact_duplicate AND e.shipment_id = s.shipment_id
       AND e.status_code = 'DELIVERED'
       AND (s.n_base < 5 OR e.event_ts <= s.last_base_ts);

    -- базовые этапы не должны идти «назад» во времени. Сравниваем только строки без
    -- других причин (иначе одна битая строка «отравит» посылку). Конфликт помечаем у обеих
    -- сторон: у этапа, который раньше по времени, но позже по порядку, и у того, что после него.
    -- Разные этапы в одно и то же время — тоже конфликт обеих строк.
    WITH b AS (
        SELECT raw_row_id, shipment_id, event_ts, status_seq
          FROM core.stg_event_clean
         WHERE NOT is_exact_duplicate AND cardinality(issues) = 0
           AND shipment_id IS NOT NULL AND event_ts IS NOT NULL AND status_seq BETWEEN 1 AND 5
    ),
    bad AS (
        SELECT DISTINCT unnest(ARRAY[x.raw_row_id, y.raw_row_id]) AS raw_row_id
          FROM b x
          JOIN b y ON y.shipment_id = x.shipment_id
                  AND ((y.event_ts > x.event_ts AND y.status_seq < x.status_seq)
                    OR (y.event_ts = x.event_ts AND y.status_seq <> x.status_seq))
    )
    UPDATE core.stg_event_clean e
       SET issues = e.issues || 'STATUS_ORDER_CONFLICT'::text
      FROM bad
     WHERE e.raw_row_id = bad.raw_row_id;

    -- 3) логические дубли: одно событие (посылка, время, статус) с одинаковыми
    --    очищенными данными — дубль; с разными данными (в т.ч. в одной строке участник
    --    пуст, в другой заполнен) — конфликт, в карантин все строки.
    --    Оригиналом считается строка с меньшим raw_row_id; он может оказаться и в карантине.
    WITH g AS (
        SELECT raw_row_id,
               row_number()  OVER w_same AS rn,
               first_value(raw_row_id) OVER w_same AS first_id,
               count(*) OVER w_same AS n_same,
               count(*) OVER (PARTITION BY shipment_id, event_ts, status_code) AS n_key
          FROM core.stg_event_clean
         WHERE NOT is_exact_duplicate
           AND shipment_id IS NOT NULL AND event_ts IS NOT NULL AND status_code IS NOT NULL
        WINDOW w_same AS (PARTITION BY shipment_id, event_ts, status_code, sender_no, receiver_no, courier_no,
                                       sender_city, receiver_city, route_from, route_to
                          ORDER BY raw_row_id)
    )
    UPDATE core.stg_event_clean e
       SET duplicate_of = CASE WHEN g.n_key = g.n_same AND g.rn > 1 THEN g.first_id END,
           issues = CASE WHEN g.n_key > g.n_same THEN e.issues || 'EVENT_KEY_CONFLICT'::text ELSE e.issues END
      FROM g
     WHERE e.raw_row_id = g.raw_row_id AND (g.rn > 1 OR g.n_key > g.n_same);

    -- 4) итог строки
    UPDATE core.stg_event_clean
       SET outcome = CASE WHEN is_exact_duplicate OR duplicate_of IS NOT NULL THEN 'DUPLICATE'
                          WHEN cardinality(issues) > 0 THEN 'QUARANTINE'
                          ELSE 'LOAD' END;
    RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Карантин — очередь ручной обработки.
-- Повторный запуск на том же RAW ничего не меняет: строка обновляется,
-- только если изменились причины или исходные данные; поля ручной обработки
-- (resolution_*) пайплайн не трогает, пока не изменились причины. Строки, которых больше нет в RAW или
-- которые перестали быть карантином, помечаются is_active = false, а не удаляются.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS quarantine (
    raw_row_id         text PRIMARY KEY,
    source_table       text NOT NULL DEFAULT 'public.raw_data_06',
    primary_reason     text NOT NULL,
    reason_codes       text[] NOT NULL,
    reason_detail      text NOT NULL,
    payload            jsonb NOT NULL,          -- исходная запись целиком
    suggested_fix      jsonb,                   -- подсказка для ручной обработки
    is_active          boolean NOT NULL DEFAULT true,
    first_detected_at  timestamptz NOT NULL DEFAULT now(),
    resolution_status  text NOT NULL DEFAULT 'NEW'
                       CHECK (resolution_status IN ('NEW', 'IN_PROGRESS', 'RESOLVED', 'REJECTED')),
    resolution_comment text,
    resolved_at        timestamptz
);
ALTER TABLE quarantine ADD COLUMN IF NOT EXISTS deactivated_at timestamptz;   -- когда запись выпала из очереди

-- Итог по каждой строке RAW: загружается / карантин / дубль
CREATE TABLE IF NOT EXISTS raw_row_outcome (
    raw_row_id text PRIMARY KEY,
    outcome    text NOT NULL CHECK (outcome IN ('LOAD', 'QUARANTINE', 'DUPLICATE')),
    detail     text
);

CREATE OR REPLACE FUNCTION step_05_quarantine()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_step interval := (SELECT value::interval FROM core.ref_setting WHERE name = 'event_step');
    n int;
BEGIN
    -- подсказки: события посылки идут с постоянным шагом от первого этапа (t0).
    -- t0 берём только по загружаемым строкам и только если он у посылки один.
    CREATE TEMP TABLE IF NOT EXISTS tmp_q (
        raw_row_id text PRIMARY KEY, primary_reason text, reason_codes text[], reason_detail text,
        payload jsonb, suggested_fix jsonb
    ) ON COMMIT DROP;
    TRUNCATE tmp_q;

    INSERT INTO tmp_q
    WITH t0 AS (
        SELECT shipment_id, min(event_ts - (status_seq - 1) * v_step) AS t0, count(*) AS n_basis
          FROM core.stg_event_clean
         WHERE outcome = 'LOAD' AND status_seq BETWEEN 1 AND 5
         GROUP BY shipment_id
        HAVING count(DISTINCT event_ts - (status_seq - 1) * v_step) = 1
    ),
    present AS (
        SELECT shipment_id, array_agg(DISTINCT status_seq) AS seqs
          FROM core.stg_event_clean
         WHERE outcome = 'LOAD'
         GROUP BY shipment_id
    ),
    q AS (
        SELECT e.*, r.shipment_id AS raw_shipment_id, r.event_datetime, r.sender_info, r.receiver_info,
               r.route_info, r.courier_info, r.status_info,
               t0.t0, t0.n_basis, present.seqs,
               extract(epoch FROM e.event_ts - t0.t0) / extract(epoch FROM v_step) AS k
          FROM core.stg_event_clean e
          JOIN core.stg_raw_row r USING (raw_row_id)
          LEFT JOIN t0 ON t0.shipment_id = e.shipment_id
          LEFT JOIN present ON present.shipment_id = e.shipment_id
         WHERE e.outcome = 'QUARANTINE'
    ),
    fx AS (
        SELECT q.*,
               CASE WHEN q.event_ts IS NULL AND q.status_seq BETWEEN 1 AND 5 AND q.t0 IS NOT NULL
                    THEN q.t0 + (q.status_seq - 1) * v_step END AS fix_ts,
               (SELECT s.seq_no FROM core.ref_status s
                 WHERE q.event_ts IS NOT NULL AND q.t0 IS NOT NULL
                   AND (q.status_seq IS NULL OR 'STATUS_MISLABELED' = ANY(q.issues))
                   AND q.k = floor(q.k) AND q.k BETWEEN 0 AND 4
                   AND s.seq_no = q.k + 1
                   AND NOT (s.seq_no = ANY(coalesce(q.seqs, '{}')))) AS fix_seq
          FROM q
    ),
    -- строки без даты и без статуса: если у посылки остался ровно один незанятый этап,
    -- восстанавливаем пару «этап + время»
    fx2 AS (
        SELECT fx.*,
               (SELECT array_agg(g)
                  FROM generate_series(1, 5) g
                 WHERE NOT g = ANY(coalesce(fx.seqs, '{}'))
                   AND NOT EXISTS (SELECT 1 FROM fx o
                                    WHERE o.shipment_id = fx.shipment_id AND o.raw_row_id <> fx.raw_row_id
                                      AND (o.status_seq = g OR o.fix_seq = g))) AS free_seqs
          FROM fx
    ),
    fx3 AS (
        SELECT fx2.raw_row_id, fx2.issues, fx2.raw_shipment_id, fx2.event_datetime, fx2.sender_info,
               fx2.receiver_info, fx2.route_info, fx2.courier_info, fx2.status_info, fx2.n_basis,
               CASE WHEN fx2.fix_ts IS NOT NULL THEN fx2.fix_ts
                    WHEN pair THEN fx2.t0 + (fx2.free_seqs[1] - 1) * v_step END AS fix_ts,
               (SELECT s.status_code FROM core.ref_status s
                 WHERE s.seq_no = CASE WHEN pair THEN fx2.free_seqs[1] ELSE fx2.fix_seq END) AS fix_status
          FROM fx2
          CROSS JOIN LATERAL (SELECT fx2.event_ts IS NULL AND fx2.t0 IS NOT NULL
                                     AND (fx2.status_seq IS NULL OR 'STATUS_MISLABELED' = ANY(fx2.issues))
                                     AND cardinality(fx2.free_seqs) = 1 AS pair) p
    )
    SELECT fx.raw_row_id,
           coalesce((SELECT rr.reason_code FROM unnest(fx.issues) i
                       JOIN core.ref_quarantine_reason rr ON rr.reason_code = i
                      ORDER BY rr.priority LIMIT 1), fx.issues[1]),
           fx.issues,
           (SELECT string_agg(coalesce(rr.description, i), '; ' ORDER BY rr.priority NULLS LAST, i)
              FROM unnest(fx.issues) i
              LEFT JOIN core.ref_quarantine_reason rr ON rr.reason_code = i),
           jsonb_build_object('shipment_id', fx.raw_shipment_id, 'event_datetime', fx.event_datetime,
                              'sender_info', fx.sender_info, 'receiver_info', fx.receiver_info,
                              'route_info', fx.route_info, 'courier_info', fx.courier_info,
                              'status_info', fx.status_info),
           CASE WHEN fx.fix_ts IS NOT NULL OR fx.fix_status IS NOT NULL THEN
               jsonb_strip_nulls(jsonb_build_object(
                   'event_ts', to_char(fx.fix_ts, 'YYYY-MM-DD HH24:MI:SS'),
                   'status_code', fx.fix_status,
                   'basis', 'события посылки идут с шагом ' || v_step || ' от первого этапа',
                   'basis_rows', fx.n_basis))
           END
      FROM fx3 fx;

    INSERT INTO core.quarantine AS t
        (raw_row_id, primary_reason, reason_codes, reason_detail, payload, suggested_fix)
    SELECT raw_row_id, primary_reason, reason_codes, reason_detail, payload, suggested_fix FROM tmp_q
    ON CONFLICT (raw_row_id) DO UPDATE
       SET primary_reason = EXCLUDED.primary_reason,
           reason_codes   = EXCLUDED.reason_codes,
           reason_detail  = EXCLUDED.reason_detail,
           payload        = EXCLUDED.payload,
           suggested_fix  = EXCLUDED.suggested_fix,
           is_active      = true,
           deactivated_at = NULL,
           -- причины изменились или запись вернулась в очередь — её нужно разобрать заново
           resolution_status = CASE WHEN t.reason_codes IS DISTINCT FROM EXCLUDED.reason_codes OR NOT t.is_active
                                    THEN 'NEW' ELSE t.resolution_status END
     WHERE (t.primary_reason, t.reason_codes, t.reason_detail, t.payload, t.suggested_fix, t.is_active)
           IS DISTINCT FROM
           (EXCLUDED.primary_reason, EXCLUDED.reason_codes, EXCLUDED.reason_detail, EXCLUDED.payload,
            EXCLUDED.suggested_fix, true);

    UPDATE core.quarantine t SET is_active = false, deactivated_at = now()
     WHERE t.is_active AND NOT EXISTS (SELECT 1 FROM tmp_q q WHERE q.raw_row_id = t.raw_row_id);

    -- итог по каждой строке RAW
    TRUNCATE core.raw_row_outcome;
    INSERT INTO core.raw_row_outcome (raw_row_id, outcome, detail)
    SELECT e.raw_row_id, e.outcome,
           CASE e.outcome WHEN 'DUPLICATE'  THEN 'копия ' || e.duplicate_of
                          WHEN 'QUARANTINE' THEN q.primary_reason
                          ELSE nullif(array_to_string(e.flags, ','), '') END
      FROM core.stg_event_clean e
      LEFT JOIN tmp_q q USING (raw_row_id);

    SELECT count(*) INTO n FROM tmp_q;
    RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Сводка обработки RAW (для защиты и quality checks)
-- ---------------------------------------------------------------------
-- unaccounted — строки текущего RAW без итога; stale — итоги строк, которых в RAW уже нет
-- (сверка по raw_row_id, а не по количеству: ловит и подменённые строки без перезапуска)
DROP VIEW IF EXISTS v_raw_processing_summary;
CREATE VIEW v_raw_processing_summary AS
WITH cur AS (
    SELECT raw_hash || ':' || row_number() OVER (PARTITION BY raw_hash) AS raw_row_id
      FROM (SELECT core.fn_raw_hash(shipment_id, event_datetime, sender_info, receiver_info,
                                           route_info, courier_info, status_info) AS raw_hash
              FROM public.raw_data_06) h
)
SELECT (SELECT count(*) FROM cur)                                                         AS raw_total,
       count(*) FILTER (WHERE o.outcome = 'LOAD')                                        AS loaded,
       count(*) FILTER (WHERE o.outcome = 'QUARANTINE')                                  AS quarantined,
       count(*) FILTER (WHERE o.outcome = 'DUPLICATE')                                   AS duplicates,
       (SELECT count(*) FROM cur c WHERE NOT EXISTS
            (SELECT 1 FROM core.raw_row_outcome x WHERE x.raw_row_id = c.raw_row_id)) AS unaccounted,
       (SELECT count(*) FROM core.raw_row_outcome x WHERE NOT EXISTS
            (SELECT 1 FROM cur c WHERE c.raw_row_id = x.raw_row_id))                      AS stale
  FROM core.raw_row_outcome o;

CREATE OR REPLACE VIEW v_quarantine_by_reason AS
SELECT q.primary_reason, r.description, count(*) AS rows,
       count(*) FILTER (WHERE q.suggested_fix IS NOT NULL) AS with_suggestion
  FROM core.quarantine q
  LEFT JOIN core.ref_quarantine_reason r ON r.reason_code = q.primary_reason
 WHERE q.is_active
 GROUP BY q.primary_reason, r.description, r.priority
 ORDER BY r.priority;

-- ---------------------------------------------------------------------
-- Запуск этапов 5–6 целиком
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_stage_5_6(
    OUT cities int, OUT persons int, OUT raw_rows int, OUT clean_rows int, OUT quarantined int)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT b.cities, b.persons INTO cities, persons FROM core.fn_build_refs() b;
    raw_rows    := core.step_02_stage_raw();
    clean_rows  := core.step_04_clean_events();
    quarantined := core.step_05_quarantine();
END $$;
