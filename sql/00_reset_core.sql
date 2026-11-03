-- Очистка core (кроме report_profile_*), RAW не трогается

DO $$
DECLARE r record;
BEGIN
    IF to_regclass('core.quarantine') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'core' AND table_name = 'quarantine' AND column_name = 'resolution_status') THEN
        IF EXISTS (SELECT 1 FROM core.quarantine WHERE resolution_status <> 'NEW') THEN
            RAISE EXCEPTION 'В core.quarantine есть записи в ручной обработке — сохраните их перед очисткой'
                  USING HINT = 'SELECT * FROM core.quarantine WHERE resolution_status <> ''NEW'';';
        END IF;
    END IF;

    FOR r IN SELECT schemaname, viewname FROM pg_views WHERE schemaname = 'core' LOOP
        EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', r.schemaname, r.viewname);
    END LOOP;

    FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'core' LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', r.schemaname, r.tablename);
    END LOOP;

    FOR r IN SELECT p.oid::regprocedure AS sig, p.prokind
               FROM pg_proc p
              WHERE p.pronamespace = 'core'::regnamespace
                AND p.proname NOT LIKE 'report\_profile\_%'
                AND p.prokind IN ('f', 'p') LOOP
        EXECUTE format('DROP %s IF EXISTS %s CASCADE',
                       CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, r.sig);
    END LOOP;
END $$;

DROP SCHEMA IF EXISTS dm CASCADE;

-- Что осталось в core
SELECT p.proname AS remaining_in_core
  FROM pg_proc p WHERE p.pronamespace = 'core'::regnamespace
UNION ALL
SELECT c.relname FROM pg_class c WHERE c.relnamespace = 'core'::regnamespace AND c.relkind IN ('r', 'v', 'm', 'S');
