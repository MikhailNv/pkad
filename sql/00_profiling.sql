-- Этап 1. Профилирование RAW

CREATE OR REPLACE FUNCTION core.report_profile_columns() RETURNS TABLE(col_name text, n_total bigint, n_null bigint, n_empty bigint, n_edge_spaces bigint, n_double_spaces bigint, n_distinct bigint, len_min integer, len_max integer)
    LANGUAGE sql STABLE
    AS $$
WITH c AS (
  SELECT 'shipment_id'::text AS col, shipment_id AS v FROM public.raw_data_06
  UNION ALL SELECT 'event_datetime', event_datetime FROM public.raw_data_06
  UNION ALL SELECT 'sender_info', sender_info FROM public.raw_data_06
  UNION ALL SELECT 'receiver_info', receiver_info FROM public.raw_data_06
  UNION ALL SELECT 'route_info', route_info FROM public.raw_data_06
  UNION ALL SELECT 'courier_info', courier_info FROM public.raw_data_06
  UNION ALL SELECT 'status_info', status_info FROM public.raw_data_06
)
SELECT col AS column_name,
       count(*) AS total,
       count(*) FILTER (WHERE v IS NULL) AS is_null,
       count(*) FILTER (WHERE btrim(v) = '') AS empty_blank,
       count(*) FILTER (WHERE v <> btrim(v)) AS edge_spaces,
       count(*) FILTER (WHERE v ~ '  ') AS double_spaces,
       count(DISTINCT v) AS distinct_cnt,
       min(length(v)) AS min_len,
       max(length(v)) AS max_len
FROM c GROUP BY col ORDER BY col
$$;

COMMENT ON FUNCTION core.report_profile_columns() IS 'Постолбцовая статистика RAW: NULL, пустые строки, пробелы по краям и двойные, число уникальных, длины. Только чтение.';

CREATE OR REPLACE FUNCTION core.report_profile_raw() RETURNS TABLE(section_name text, metric_name text, metric_value text)
    LANGUAGE sql STABLE
    AS $_$
WITH cal AS (
  SELECT g::date AS dt FROM generate_series('2024-01-01'::date,'2027-12-31'::date,'1 day') AS g
),
raw AS (
  SELECT ctid, shipment_id, event_datetime, sender_info, receiver_info, route_info, courier_info, status_info
  FROM public.raw_data_06
),
p AS (
  SELECT raw.*,
    CASE
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{4}' THEN 'dmy4'
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{2}\s' THEN 'dmy2'
      WHEN event_datetime ~ '^\d{4}-\d{2}-\d{2}' THEN 'ymd'
      WHEN event_datetime ~ '^\d{4}/\d{2}/\d{2}' THEN 'ymds'
      WHEN event_datetime ~ '^\d{2}/\d{2}/\d{4}' THEN 'dmys'
      WHEN event_datetime ~ '^\d{8}\s' THEN 'ymdc'
      WHEN event_datetime ~ '^\d{2} [A-Za-z]{3} \d{4}' THEN 'dmon'
    END AS fmt,
    -- date parts
    CASE
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{4}' THEN (regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{4})'))[3]::int
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{2}\s' THEN 2000+(regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{2})\s'))[3]::int
      WHEN event_datetime ~ '^\d{4}-\d{2}-\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})-(\d{2})-(\d{2})'))[1]::int
      WHEN event_datetime ~ '^\d{4}/\d{2}/\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})/(\d{2})/(\d{2})'))[1]::int
      WHEN event_datetime ~ '^\d{2}/\d{2}/\d{4}' THEN (regexp_match(event_datetime,'^(\d{2})/(\d{2})/(\d{4})'))[3]::int
      WHEN event_datetime ~ '^\d{8}\s' THEN (regexp_match(event_datetime,'^(\d{4})(\d{2})(\d{2})\s'))[1]::int
      WHEN event_datetime ~ '^\d{2} [A-Za-z]{3} \d{4}' THEN (regexp_match(event_datetime,'^(\d{2}) ([A-Za-z]{3}) (\d{4})'))[3]::int
    END AS y,
    CASE
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{4}' THEN (regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{4})'))[2]::int
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{2}\s' THEN (regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{2})\s'))[2]::int
      WHEN event_datetime ~ '^\d{4}-\d{2}-\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})-(\d{2})-(\d{2})'))[2]::int
      WHEN event_datetime ~ '^\d{4}/\d{2}/\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})/(\d{2})/(\d{2})'))[2]::int
      WHEN event_datetime ~ '^\d{2}/\d{2}/\d{4}' THEN (regexp_match(event_datetime,'^(\d{2})/(\d{2})/(\d{4})'))[2]::int
      WHEN event_datetime ~ '^\d{8}\s' THEN (regexp_match(event_datetime,'^(\d{4})(\d{2})(\d{2})\s'))[2]::int
      WHEN event_datetime ~ '^\d{2} [A-Za-z]{3} \d{4}' THEN CASE upper(substring(event_datetime from 4 for 3))
             WHEN 'JAN' THEN 1 WHEN 'FEB' THEN 2 WHEN 'MAR' THEN 3 WHEN 'APR' THEN 4 WHEN 'MAY' THEN 5 WHEN 'JUN' THEN 6
             WHEN 'JUL' THEN 7 WHEN 'AUG' THEN 8 WHEN 'SEP' THEN 9 WHEN 'OCT' THEN 10 WHEN 'NOV' THEN 11 WHEN 'DEC' THEN 12 END
    END AS m,
    CASE
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{4}' THEN (regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{4})'))[1]::int
      WHEN event_datetime ~ '^\s*\d{2}\.\d{2}\.\d{2}\s' THEN (regexp_match(event_datetime,'^\s*(\d{2})\.(\d{2})\.(\d{2})\s'))[1]::int
      WHEN event_datetime ~ '^\d{4}-\d{2}-\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})-(\d{2})-(\d{2})'))[3]::int
      WHEN event_datetime ~ '^\d{4}/\d{2}/\d{2}' THEN (regexp_match(event_datetime,'^(\d{4})/(\d{2})/(\d{2})'))[3]::int
      WHEN event_datetime ~ '^\d{2}/\d{2}/\d{4}' THEN (regexp_match(event_datetime,'^(\d{2})/(\d{2})/(\d{4})'))[1]::int
      WHEN event_datetime ~ '^\d{8}\s' THEN (regexp_match(event_datetime,'^(\d{4})(\d{2})(\d{2})\s'))[3]::int
      WHEN event_datetime ~ '^\d{2} [A-Za-z]{3} \d{4}' THEN (regexp_match(event_datetime,'^(\d{2}) ([A-Za-z]{3}) (\d{4})'))[1]::int
    END AS d,
    -- time parts
    CASE
      WHEN event_datetime ~ '^\d{8}\s' THEN substring(event_datetime from 10 for 2)::int
      WHEN event_datetime ~ ':\d{2}' THEN (regexp_match(event_datetime,'(\d{1,2}):(\d{2})'))[1]::int
      ELSE 0
    END AS hh_raw,
    CASE WHEN event_datetime ~ ':\d{2}' THEN (regexp_match(event_datetime,'(\d{1,2}):(\d{2})'))[2]::int
         WHEN event_datetime ~ '^\d{8}\s' THEN substring(event_datetime from 12 for 2)::int
         ELSE 0 END AS mi_raw,
    CASE WHEN event_datetime ~ ':\d{2}:\d{2}' THEN (regexp_match(event_datetime,'\d{2}:\d{2}:(\d{2})'))[1]::int ELSE 0 END AS ss_raw,
    CASE WHEN event_datetime ~ '(AM|PM)$' THEN substring(event_datetime from '(\d{1,2}):\d{2} (AM|PM)')::int END AS hh12,
    CASE WHEN event_datetime ~ '(AM|PM)$' THEN substring(event_datetime from '\d{1,2}:\d{2} (AM|PM)') END AS meridiem
  FROM raw
),
v AS (
  SELECT p.*, t.dt AS valid_dt
  FROM p LEFT JOIN cal t
    ON extract(year from t.dt)=p.y AND extract(month from t.dt)=p.m AND extract(day from t.dt)=p.d
),
n AS (
  SELECT v.*,
    (coalesce(hh_raw,0) > 23 OR coalesce(mi_raw,0) > 59 OR coalesce(ss_raw,0) > 59
       OR (meridiem IS NOT NULL AND (hh12 < 1 OR hh12 > 12))) AS time_out_of_range,
    'PKG-'||lpad(regexp_replace(shipment_id,'\D','','g'),6,'0') AS canon_id,
    CASE WHEN valid_dt IS NULL OR (coalesce(hh_raw,0) > 23 OR coalesce(mi_raw,0) > 59 OR coalesce(ss_raw,0) > 59
              OR (meridiem IS NOT NULL AND (hh12 < 1 OR hh12 > 12))) THEN NULL
         ELSE make_timestamp(y, m, d,
              CASE WHEN meridiem='AM' THEN CASE WHEN hh12=12 THEN 0 ELSE hh12 END
                   WHEN meridiem='PM' THEN CASE WHEN hh12=12 THEN 12 ELSE hh12+12 END
                   ELSE hh_raw END,
              coalesce(mi_raw,0), coalesce(ss_raw,0))
    END AS ts,
    CASE WHEN valid_dt IS NULL THEN NULL
         ELSE make_date(y,m,d) END AS event_date
  FROM v
),
ts_bad AS (SELECT * FROM n)
, st AS (
  SELECT canon_id, ts, lower(btrim(status_info)) AS s
  FROM ts_bad WHERE ts IS NOT NULL AND lower(btrim(status_info)) <> '???'
)
, ord AS (
  SELECT canon_id,
         CASE s WHEN 'создано' THEN 1 WHEN 'принято' THEN 2 WHEN 'сортировочный центр' THEN 3
                WHEN 'в пути' THEN 4 WHEN 'передано курьеру' THEN 5 WHEN 'доставлено' THEN 6 END AS o,
         lag(CASE s WHEN 'создано' THEN 1 WHEN 'принято' THEN 2 WHEN 'сортировочный центр' THEN 3
                    WHEN 'в пути' THEN 4 WHEN 'передано курьеру' THEN 5 WHEN 'доставлено' THEN 6 END)
             OVER (PARTITION BY canon_id ORDER BY ts) AS prev_o
  FROM st
)
, viol AS (SELECT count(DISTINCT canon_id) AS c FROM ord WHERE o < prev_o)
, rt AS (
  SELECT canon_id,
         btrim(split_part(sender_info,'/',2)) AS s_city,
         btrim(split_part(receiver_info,'/',2)) AS r_city,
         CASE WHEN route_info LIKE 'из %' THEN btrim(split_part(substring(route_info from 4),' в ',1))
              WHEN route_info LIKE '%->%' THEN btrim(split_part(route_info,'->',1))
              ELSE btrim(split_part(route_info,'/',1)) END AS f_city,
         CASE WHEN route_info LIKE 'из %' THEN btrim(split_part(substring(route_info from 4),' в ',2))
              WHEN route_info LIKE '%->%' THEN btrim(split_part(route_info,'->',2))
              ELSE btrim(split_part(route_info,'/',2)) END AS t_city
  FROM ts_bad
)
SELECT * FROM (
  SELECT '1. Объём' AS section, 'Строк в RAW' AS metric, count(*)::text AS value FROM ts_bad
  UNION ALL SELECT '1. Объём', 'Уникальных shipment_id (сырых)', count(DISTINCT shipment_id)::text FROM ts_bad
  UNION ALL SELECT '1. Объём', 'Уникальных посылок (канон.)', count(DISTINCT canon_id)::text FROM ts_bad
  UNION ALL SELECT '1. Объём', 'Событий на посылку (среднее)',
       round(count(*)::numeric / count(DISTINCT canon_id), 2)::text FROM ts_bad

  UNION ALL SELECT '2. Дубли', 'Групп полных дублей', (SELECT count(*)::text FROM (
       SELECT 1 FROM public.raw_data_06
       GROUP BY shipment_id,event_datetime,sender_info,receiver_info,route_info,courier_info,status_info
       HAVING count(*) > 1) x)
  UNION ALL SELECT '2. Дубли', 'Лишних строк-дублей', ((SELECT count(*) FROM public.raw_data_06) -
       (SELECT count(*) FROM (SELECT DISTINCT shipment_id,event_datetime,sender_info,receiver_info,route_info,courier_info,status_info FROM public.raw_data_06) y))::text
  UNION ALL SELECT '2. Дубли', 'Логических дублей (ID+время+статус)', (SELECT count(*)::text FROM (
       SELECT 1 FROM ts_bad WHERE ts IS NOT NULL GROUP BY canon_id, ts, lower(btrim(status_info)) HAVING count(*) > 1) z)

  UNION ALL SELECT '3. Даты', 'Распознан формат', count(*) FILTER (WHERE fmt IS NOT NULL)::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Разобрано в timestamp', count(*) FILTER (WHERE ts IS NOT NULL)::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Пустая строка', count(*) FILTER (WHERE btrim(event_datetime)='')::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Литерал ''NULL''', count(*) FILTER (WHERE upper(btrim(event_datetime))='NULL')::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Плейсхолдер (сегодня/неизвестно)',
       count(*) FILTER (WHERE fmt IS NULL AND btrim(event_datetime)<>'' AND upper(btrim(event_datetime))<>'NULL')::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Невалидная календарная дата', count(*) FILTER (WHERE fmt IS NOT NULL AND valid_dt IS NULL)::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Невалидное время', count(*) FILTER (WHERE time_out_of_range)::text FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Минимальная дата', coalesce(to_char(min(ts),'YYYY-MM-DD HH24:MI'),'—') FROM ts_bad
  UNION ALL SELECT '3. Даты', 'Максимальная дата', coalesce(to_char(max(ts),'YYYY-MM-DD HH24:MI'),'—') FROM ts_bad

  UNION ALL SELECT '4. Статусы', 'Различных написаний', count(DISTINCT status_info)::text FROM ts_bad
  UNION ALL SELECT '4. Статусы', 'Канонических статусов (без ???)', count(DISTINCT lower(btrim(status_info))) FILTER (WHERE lower(btrim(status_info)) <> '???')::text FROM ts_bad
  UNION ALL SELECT '4. Статусы', 'Строк с ''???''', count(*) FILTER (WHERE lower(btrim(status_info))='???')::text FROM ts_bad

  UNION ALL SELECT '5. Справочники', 'Городов',
       count(DISTINCT btrim(split_part(sender_info,'/',2)))::text FROM ts_bad
  UNION ALL SELECT '5. Справочники', 'Кодов отправителя (S##)',
       count(DISTINCT substring(sender_info from 'S([0-9]{1,2})'))::text FROM ts_bad
  UNION ALL SELECT '5. Справочники', 'Маршрутов (пар городов)',
       count(DISTINCT (btrim(split_part(sender_info,'/',2)), btrim(split_part(receiver_info,'/',2))))::text FROM ts_bad

  UNION ALL SELECT '6. Противоречия', 'route ≠ города участников',
       count(*) FILTER (WHERE s_city <> f_city OR r_city <> t_city)::text FROM rt
  UNION ALL SELECT '6. Противоречия', '''Передано курьеру'' без курьера',
       count(*) FILTER (WHERE lower(btrim(status_info))='передано курьеру'
                          AND (btrim(courier_info)='' OR courier_info ~* 'не указан'))::text FROM ts_bad
  UNION ALL SELECT '6. Противоречия', 'Посылок с нарушением порядка статусов',
       (SELECT c::text FROM viol)
  UNION ALL SELECT '6. Противоречия', 'Посылок «город → тот же город»',
       count(DISTINCT canon_id) FILTER (WHERE s_city = r_city)::text FROM rt

  UNION ALL SELECT '7. Прогноз карантина', 'Карантин (дата/статус)',
       ((SELECT count(*) FROM (SELECT DISTINCT shipment_id,event_datetime,sender_info,receiver_info,route_info,courier_info,status_info, ts FROM ts_bad) u
         WHERE ts IS NULL OR lower(btrim(status_info))='???'))::text
  UNION ALL SELECT '7. Прогноз карантина', 'К загрузке в core',
       ((SELECT count(*) FROM (SELECT DISTINCT shipment_id,event_datetime,sender_info,receiver_info,route_info,courier_info,status_info, ts FROM ts_bad) u
         WHERE ts IS NOT NULL AND lower(btrim(status_info))<>'???'))::text
) q
$_$;

COMMENT ON FUNCTION core.report_profile_raw() IS 'Профилирование public.raw_data_06: объём, дубли, форматы дат, статусы, справочники, противоречия, прогноз карантина. Только чтение.';
