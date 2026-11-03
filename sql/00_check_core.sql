-- Проверка: нет ли в core таблиц другой структуры

DO $$
DECLARE
    v_bad text[] := '{}';
BEGIN
    IF to_regclass('core.quarantine_row') IS NOT NULL THEN
        v_bad := v_bad || 'core.quarantine_row (таблица DDL этапа 3, в решении — core.quarantine)'::text;
    END IF;

    IF to_regclass('core.stg_raw_row') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'core' AND table_name = 'stg_raw_row' AND column_name = 'occurrence') THEN
        v_bad := v_bad || 'core.stg_raw_row (нет столбца occurrence)'::text;
    END IF;

    IF to_regclass('core.shipment_event') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'core' AND table_name = 'shipment_event' AND column_name = 'raw_hash') THEN
        v_bad := v_bad || 'core.shipment_event (нет столбца raw_hash)'::text;
    END IF;

    IF to_regclass('core.ref_quality_flag') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'core' AND table_name = 'ref_quality_flag' AND column_name = 'source') THEN
        v_bad := v_bad || 'core.ref_quality_flag (нет столбца source)'::text;
    END IF;

    IF to_regclass('core.ref_quarantine_reason') IS NOT NULL AND EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE contype = 'f' AND confrelid = to_regclass('core.ref_quarantine_reason')
           AND conrelid IS DISTINCT FROM to_regclass('core.quarantine')) THEN
        v_bad := v_bad || 'core.ref_quarantine_reason (на неё ссылается чужая таблица)'::text;
    END IF;

    IF to_regclass('core.person') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'core' AND table_name = 'person' AND column_name = 'person_code') THEN
        v_bad := v_bad || 'core.person (нет столбца person_code)'::text;
    END IF;

    IF cardinality(v_bad) > 0 THEN
        RAISE EXCEPTION E'В схеме core есть таблицы другой структуры:\n  - %',
                        array_to_string(v_bad, E'\n  - ')
              USING HINT = 'Выполните team06_reset_core.sql (sql/00_reset_core.sql): он удаляет объекты core, '
                        || 'кроме функций профилирования report_profile_*; RAW не трогает. Затем запустите этот скрипт заново.';
    END IF;
END $$;
