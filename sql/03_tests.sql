-- Тесты функций разбора: ожидаемое значение / ожидаемая ошибка. Выводит только упавшие.
SET search_path = core, public;

-- Дата и время
SELECT 'ts' AS fn, input, expected_ts, expected_err, (fn_parse_ts(input)).ts AS got_ts, (fn_parse_ts(input)).err AS got_err
FROM (VALUES
    ('01.01.2026 09:00',        '2026-01-01 09:00'::timestamp, NULL),
    (' 01.01.2026 10:50 ',      '2026-01-01 10:50', NULL),
    ('01.01.2026 в 09:30',      '2026-01-01 09:30', NULL),
    ('01.01.2026 03:20 PM',     '2026-01-01 15:20', NULL),
    ('01.01.2026 12:05 AM',     '2026-01-01 00:05', NULL),
    ('01.01.2026 12:05 PM',     '2026-01-01 12:05', NULL),
    ('2026-01-01 08:10:00',     '2026-01-01 08:10', NULL),
    ('2026-01-01T09:40:00',     '2026-01-01 09:40', NULL),
    ('01/01/2026 10:00',        '2026-01-01 10:00', NULL),
    ('13/01/2026 14:50',        '2026-01-13 14:50', NULL),
    ('2026/01/01 08:20',        '2026-01-01 08:20', NULL),
    ('01.01.26 08:30',          '2026-01-01 08:30', NULL),
    ('20260101 1010',           '2026-01-01 10:10', NULL),
    ('20260101 101530',         '2026-01-01 10:15:30', NULL),
    ('01 Jan 2026 16:50',       '2026-01-01 16:50', NULL),
    ('5 мар 2026 7:05',         '2026-03-05 07:05', NULL),
    ('05 марта 2026 в 07:05',   '2026-03-05 07:05', NULL),
    ('29.02.2024 10:00',        '2024-02-29 10:00', NULL),
    ('',                        NULL, 'DT_EMPTY'),
    (NULL,                      NULL, 'DT_EMPTY'),
    ('NULL',                    NULL, 'DT_PLACEHOLDER'),
    ('неизвестно',              NULL, 'DT_PLACEHOLDER'),
    ('сегодня утром',           NULL, 'DT_RELATIVE'),
    ('31.02.2026 12:00',        NULL, 'DT_INVALID_DATE'),
    ('29.02.2026 10:00',        NULL, 'DT_INVALID_DATE'),
    ('13.13.2026 10:00',        NULL, 'DT_INVALID_DATE'),
    ('15.03.2026 25:61',        NULL, 'DT_INVALID_TIME'),
    ('01.01.2026 13:00 PM',     NULL, 'DT_INVALID_TIME'),
    ('01.01.2026',              NULL, 'DT_NO_TIME'),
    ('завтра в 10',             NULL, 'DT_RELATIVE'),
    ('1st of January',          NULL, 'DT_UNKNOWN_FORMAT'),
    ('01 Foo 2026 10:00',       NULL, 'DT_UNKNOWN_FORMAT'),
    ('01.01.0000 10:00',        NULL, 'DT_INVALID_DATE'),
    ('00000101 1010',           NULL, 'DT_INVALID_DATE'),
    ('01.01.2026 10:00 (днём)', NULL, 'DT_UNKNOWN_FORMAT'),
    (E'\u200B01.01.2026 10:00', '2026-01-01 10:00', NULL)
) t(input, expected_ts, expected_err)
WHERE (fn_parse_ts(input)).ts IS DISTINCT FROM expected_ts
   OR (fn_parse_ts(input)).err IS DISTINCT FROM expected_err;

-- ID посылки
SELECT 'id' AS fn, input, expected, (fn_parse_shipment_id(input)).*
FROM (VALUES ('PKG-900001','PKG-900001'), ('№ PKG 900005','PKG-900005'), ('900006','PKG-900006'),
             (' pkg 900007 ','PKG-900007'), ('PKG-90001',NULL), ('PKG-9000011',NULL), ('ABC-900001',NULL), ('',NULL),
             ('PKG–900001','PKG-900001'), ('PKG-PKG-900001',NULL), ('PKG900001PKG',NULL), ('9.0.0.0.0.1',NULL), ('900-001',NULL)) t(input, expected)
WHERE (fn_parse_shipment_id(input)).shipment_id IS DISTINCT FROM expected;

-- Статус
SELECT 'status' AS fn, input, expected, (fn_parse_status(input)).*
FROM (VALUES ('Создано','CREATED'), ('  в  пути ','IN_TRANSIT'), ('СОРТИРОВОЧНЫЙ ЦЕНТР','SORTING'),
             ('Передано курьеру.','HANDED_TO_COURIER'), ('???',NULL), ('Потеряно',NULL),
             (E'Создано\u200B','CREATED'), (E'\uFEFFСоздано','CREATED'), ('Доставлено?',NULL)) t(input, expected)
WHERE (fn_parse_status(input)).status_code IS DISTINCT FROM expected;

-- Маршрут
SELECT 'route' AS fn, input, exp_from, exp_to, (fn_parse_route(input)).*
FROM (VALUES ('из Санкт-Петербург в Москва','Санкт-Петербург','Москва'),
             ('Санкт-Петербург -> Москва','Санкт-Петербург','Москва'),
             ('Санкт-Петербург/Москва','Санкт-Петербург','Москва'),
             ('СПб → г. Москва','Санкт-Петербург','Москва'),
             ('Казань - Омск','Казань','Омск'),
             ('Казань Омск',NULL,NULL),
             ('Казань -> Урюпинск',NULL,NULL)) t(input, exp_from, exp_to)
WHERE (fn_parse_route(input)).from_city IS DISTINCT FROM exp_from
   OR (fn_parse_route(input)).to_city   IS DISTINCT FROM exp_to;

-- ФИО (роль не передаём, кроме отдельных случаев)
SELECT 'person' AS fn, input, role, exp_no, exp_err, (fn_parse_person(input, role)).*
FROM (VALUES
    -- формы из RAW
    ('Голубев Е.М.', NULL, 18, NULL), ('Н.М. Зайцев', NULL, 15, NULL), ('ВОЛКОВ НИКОЛАЙ', NULL, 7, NULL),
    ('Ирина Павлов', NULL, 16, NULL), ('Волков Николай Николаевич', NULL, 7, NULL), ('[C10] Роман Козлов', 'C', 10, NULL),
    ('C10 Козлов Роман', 'C', 10, NULL), ('Козлов Роман (C10)', 'C', 10, NULL), ('Иванов_Алексей', NULL, 1, NULL),
    ('Богданов, Юлия', NULL, 20, NULL), ('М0р0з0в Анна', NULL, 12, NULL), ('А.Лебедев', NULL, 9, NULL),
    ('Роман К.', NULL, 10, NULL), ('Татьяна С.', NULL, 17, NULL), ('Волков', NULL, 7, NULL),
    ('Волков Н.Н.', NULL, 7, NULL), ('Иванов Алексей А.', NULL, 1, NULL),
    ('  Петров   Сергей  ', NULL, 2, NULL), ('s3 Сидоров Иван', 's', 3, NULL), ('СидоровS3', NULL, 3, NULL),
    ('S3_Сидоров Иван', NULL, 3, NULL),
    -- пусто / только код
    ('не указан', NULL, NULL, 'PERSON_EMPTY'), ('', NULL, NULL, 'PERSON_EMPTY'), ('[S3]', NULL, NULL, 'PERSON_CODE_ONLY'),
    ('[S3] не указан', NULL, NULL, 'PERSON_CODE_ONLY'), ('S3 ???', NULL, NULL, 'PERSON_CODE_ONLY'),
    -- мусор не должен становиться «не указан»
    ('John Smith', NULL, NULL, 'PERSON_INVALID'), ('12345', NULL, NULL, 'PERSON_INVALID'),
    ('Волков 7', NULL, NULL, 'PERSON_INVALID'), ('Волков1', NULL, NULL, 'PERSON_INVALID'), ('S007 Волков', NULL, NULL, 'PERSON_INVALID'),
    -- небезопасные формы
    ('Николай', NULL, NULL, 'PERSON_UNKNOWN'), ('Мария Алексеевна', NULL, NULL, 'PERSON_UNKNOWN'),
    ('Волков Волков', NULL, NULL, 'PERSON_UNKNOWN'), ('Иванов Алексей Алексеевич Иванов', NULL, NULL, 'PERSON_UNKNOWN'),
    ('Волков В.', NULL, NULL, 'PERSON_UNKNOWN'), ('Волков Н.Н.Н.Н.', NULL, NULL, 'PERSON_UNKNOWN'),
    ('Иванов Алексеевич', NULL, NULL, 'PERSON_UNKNOWN'),
    ('Петров Иван', NULL, NULL, 'PERSON_UNKNOWN'), ('Пупкин Василий', NULL, NULL, 'PERSON_UNKNOWN'),
    ('С.', NULL, NULL, 'PERSON_UNKNOWN'), ('-Волков', NULL, 7, NULL),
    ('Иванов ?', NULL, NULL, 'PERSON_INVALID'), ('Иванов!', NULL, NULL, 'PERSON_INVALID'), ('Иванов é', NULL, NULL, 'PERSON_INVALID'),
    ('Волков 0', NULL, NULL, 'PERSON_INVALID'),
    -- коды
    ('[S5] Иванов Алексей', NULL, NULL, 'PERSON_CODE_CONFLICT'), ('S3-Волков', NULL, NULL, 'PERSON_CODE_CONFLICT'),
    ('c10 Орлов', NULL, NULL, 'PERSON_CODE_CONFLICT'), ('ВолковS3', NULL, NULL, 'PERSON_CODE_CONFLICT'),
    ('C10 C7 Козлов', NULL, NULL, 'PERSON_CODE_CONFLICT'), ('[S10] Козлов Роман', 'C', NULL, 'PERSON_ROLE_MISMATCH')
) t(input, role, exp_no, exp_err)
WHERE (fn_parse_person(input, role)).person_no IS DISTINCT FROM exp_no
   OR (fn_parse_person(input, role)).err IS DISTINCT FROM exp_err;

-- Защита допущения DD/MM: в RAW не должно быть дат с «месяцем» > 12 во втором поле
SELECT 'dm_guard' AS check_name, count(*) AS bad_rows
  FROM public.raw_data_06
 WHERE btrim(event_datetime) ~ '^\d{1,2}[./-]\d{1,2}[./-]\d{2,4}'
   AND (regexp_match(btrim(event_datetime), '^\d{1,2}[./-](\d{1,2})'))[1]::int > 12
HAVING count(*) > 0;

-- Сверка дат с закономерностью данных: событие = t0 + 8ч·(seq−1).
-- Независимая проверка парсера: посылок с разными t0 должно быть 0.
WITH e AS (
    SELECT (fn_parse_shipment_id(shipment_id)).shipment_id AS sid,
           (fn_parse_ts(event_datetime)).ts AS ts,
           (fn_parse_status(status_info)).status_code AS st
      FROM public.raw_data_06
)
SELECT 'ts_vs_8h_rule' AS check_name,
       sum(n_ev) AS events_checked,
       count(*) AS shipments_checked,
       count(*) FILTER (WHERE n_t0 > 1) AS shipments_with_conflict
  FROM (SELECT e.sid, count(*) AS n_ev, count(DISTINCT e.ts - (s.seq_no - 1) * interval '8 hours') AS n_t0
          FROM e JOIN ref_status s ON s.status_code = e.st
         WHERE e.ts IS NOT NULL AND e.st <> 'DELIVERED'
         GROUP BY e.sid) x;
