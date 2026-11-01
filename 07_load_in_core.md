# Этапы 07 - 08. Загрузка данных в Core  

**Команда 06 · «Доставка посылок»** 

Этап 7.	Загрузить корректные данные в core. Повторный запуск pipeline должен быть идемпотентным: при неизменном RAW итоговые таблицы и показатели не изменяются, дубли не появляются.
Этап 8.	Добавить проверки качества данных и контроль результатов загрузки.


## 1. Развёртывание и запуск (все объекты — в схеме `core`):

| Файл | Что внутри |
| :--- | :--- |
| `sql/06_load_in_core.sql` | Процедура загрузки данных в core схему из созданной на предыдущем этапе таблицы core.stg_event_clean  |


**Создание процедуры** 

```sql
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

-- 4. Заполнение таблицы core.event_status
INSERT INTO core.event_status (status_id, status_code, status_name, seq_no, is_terminal)
VALUES
    (1, 'CREATED',           'Создано',             1, false),
    (2, 'ACCEPTED',          'Принято',             2, false),
    (3, 'SORTING',           'Сортировочный центр', 3, false),
    (4, 'IN_TRANSIT',        'В пути',              4, false),
    (5, 'HANDED_TO_COURIER', 'Передано курьеру',    5, false),
    (6, 'DELIVERED',         'Доставлено',          6, true);

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


END;
$$;                        
```
**Запуск процедуры** 

```sql
BEGIN;
CALL core.step_06_load_in_core();
SELECT COUNT(*) AS loaded_events FROM core.shipment_event;

COMMIT;                          
```


## 2. Pipeline

Добавлена функция core.run_pipeline() по последовательному запуску шагов

| Шаг | Функция\Процедура | Что делает |
| :--- | :--- | :--- |
| 1 | `core.step_02_stage_raw()` | снимок RAW со стабильным `raw_row_id`, точные дубли |
| 2 | `core.step_04_clean_events()` | разбор полей, проверки уровня записи и посылки, итог строки |
| 3 | `core.step_05_quarantine()` | карантин и итог по каждой строке RAW |
| 1 | `core.step_06_load_in_core` | Записывает даныне в целевые таблицы |

```sql
--SELECT * FROM core.run_pipeline();

CREATE OR REPLACE FUNCTION core.run_pipeline(
    OUT raw_rows    integer,
    OUT clean_rows  integer,
    OUT quarantined integer
)
RETURNS record
LANGUAGE plpgsql
AS $function$
BEGIN
    -- Не допускаем параллельных запусков пайплайна
    PERFORM pg_advisory_xact_lock(8, 2026);

    raw_rows    := core.step_02_stage_raw();
    clean_rows  := core.step_04_clean_events();
    quarantined := core.step_05_quarantine();
    CALL core.step_06_load_in_core();
END;
$function$
;

```


## Проверка результата

| Показатель | Значение |
| :--- | ---: |
| Количество городов в core.city | **8** |
| shipment_event | **8 727** |
| Уникальных ФИО (core.person) | **20** |
| Уникальных маршрута (core.route) | **64** |
| core.event_status | **6** |
| Уникальных отправлений (core.shipment) | **2000** |


```sql
select 'city', COUNT(*) FROM core.city
UNION ALL
select 'person', COUNT(*) FROM core.person
UNION ALL
select 'route', COUNT(*) FROM core.route
UNION ALL
select 'shipment', COUNT(*) FROM core.shipment
UNION ALL
select 'shipment_event', COUNT(*) FROM core.shipment_event;
```

Функция core.check_core_counts() сравнивает количество записанное в CORE с другими таблицами.

| pair | core_count | ref\raw_count | equal |
| --- | --- | --- | --- |
|core.city vs ref_city|	8|	8|	true|
|core.person vs ref_person|	20|	20|	true|
|core.shipment vs raw_data_06 (unique shipment_id)|	2000|	2000|	true|
|core.route vs raw_data_06 (unique route combinations)|	64|	64|	true|
|core.shipment_event vs raw_row_outcome (LOAD)|	8727|	8727|	true|

## Прочее

В core.shipment.shipment_id и core.shipment_event.shipment_id 
Тип изменен на CHAR(10)
Количество символов в номер отправления (PKG-XXXXXX) - 10

