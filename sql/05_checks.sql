-- Контроль результатов этапов 5–6: хеши таблиц (для сравнения двух запусков) и инварианты
SET search_path = core, public;

-- Отпечатки таблиц: при неизменном RAW два запуска подряд должны дать одинаковые значения
SELECT 'stg_raw_row' AS tbl, count(*) AS rows, md5(string_agg(t::text, '|' ORDER BY raw_row_id)) AS fingerprint FROM stg_raw_row t
UNION ALL
SELECT 'stg_event_clean', count(*), md5(string_agg(t::text, '|' ORDER BY raw_row_id)) FROM stg_event_clean t
UNION ALL
SELECT 'quarantine', count(*), md5(string_agg(t::text, '|' ORDER BY raw_row_id)) FROM quarantine t
UNION ALL
SELECT 'raw_row_outcome', count(*), md5(string_agg(t::text, '|' ORDER BY raw_row_id)) FROM raw_row_outcome t
UNION ALL
SELECT 'ref_person', count(*), md5(string_agg(t::text, '|' ORDER BY person_no)) FROM ref_person t
UNION ALL
SELECT 'ref_city', count(*), md5(string_agg(t::text, '|' ORDER BY city_norm)) FROM ref_city t
ORDER BY tbl;

-- Инварианты: каждая проверка должна вернуть 0
SELECT check_name, violations FROM (
    SELECT 'неучтённые строки RAW' AS check_name, (SELECT unaccounted FROM v_raw_processing_summary) AS violations
    UNION ALL
    SELECT 'итоги строк, которых нет в RAW', (SELECT stale FROM v_raw_processing_summary)
    UNION ALL
    SELECT 'баланс RAW = загружено + карантин + дубли',
           (SELECT raw_total - loaded - quarantined - duplicates FROM v_raw_processing_summary)
    UNION ALL
    SELECT 'активный карантин ≠ QUARANTINE в итогах',
           (SELECT count(*) FROM (SELECT raw_row_id FROM quarantine WHERE is_active
                                  EXCEPT SELECT raw_row_id FROM raw_row_outcome WHERE outcome = 'QUARANTINE') a)
         + (SELECT count(*) FROM (SELECT raw_row_id FROM raw_row_outcome WHERE outcome = 'QUARANTINE'
                                  EXCEPT SELECT raw_row_id FROM quarantine WHERE is_active) b)
    UNION ALL
    SELECT 'дубль ссылается на несуществующий оригинал или на другой дубль',
           (SELECT count(*) FROM stg_event_clean d
             LEFT JOIN stg_event_clean o ON o.raw_row_id = d.duplicate_of
             WHERE d.outcome = 'DUPLICATE' AND (o.raw_row_id IS NULL OR o.outcome = 'DUPLICATE'))
    UNION ALL
    SELECT 'причина карантина не из справочника',
           (SELECT count(*) FROM quarantine q, unnest(q.reason_codes) r
             WHERE q.is_active AND r NOT IN (SELECT reason_code FROM ref_quarantine_reason))
    UNION ALL
    SELECT 'загружаемая строка без обязательных полей',
           (SELECT count(*) FROM stg_event_clean
             WHERE outcome = 'LOAD' AND (shipment_id IS NULL OR event_ts IS NULL OR status_code IS NULL
                                         OR route_from IS NULL OR sender_city IS NULL OR receiver_city IS NULL))
    UNION ALL
    SELECT 'повтор ключа события среди загружаемых',
           (SELECT count(*) - count(DISTINCT (shipment_id, event_ts, status_code))
              FROM stg_event_clean WHERE outcome = 'LOAD')
    UNION ALL
    SELECT 'карантин без исходной записи',
           (SELECT count(*) FROM quarantine WHERE payload IS NULL OR payload = '{}'::jsonb)
) c;
