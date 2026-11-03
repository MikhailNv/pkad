-- Оркестратор: SELECT * FROM core.run_pipeline();

SET search_path = core, public;

-- Шаг 01
CREATE OR REPLACE FUNCTION core.step_01_build_refs(OUT cities int, OUT persons int, OUT issues int)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT b.cities, b.persons, b.issues INTO cities, persons, issues FROM core.fn_build_refs() b;
END $$;

-- Журнал шагов
CREATE OR REPLACE FUNCTION core.fn_log_step(p_run_id bigint, p_no int, p_name text, p_result text, p_t0 timestamptz)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO core.run_step_log (run_id, step_no, step_name, result, seconds)
    VALUES (p_run_id, p_no, p_name, p_result,
            round(extract(epoch FROM clock_timestamp() - p_t0)::numeric, 3));
$$;

-- Меняется тип результата
DROP FUNCTION IF EXISTS core.run_pipeline();

CREATE FUNCTION core.run_pipeline()
RETURNS TABLE (run_id bigint, step_no int, step_name text, result text, seconds numeric)
LANGUAGE plpgsql
SET search_path = core, public
AS $$
#variable_conflict use_column
DECLARE
    v_run   bigint;
    v_t0    timestamptz;
    v_n     int;
    v_res   text;
    v_fail  int;
    v_warn  int;
BEGIN
    -- Без параллельных запусков
    PERFORM pg_advisory_xact_lock(8, 2026);

    INSERT INTO core.etl_run_log (started_at, status, raw_fingerprint)
    VALUES (clock_timestamp(), 'RUNNING', core.fn_raw_fingerprint())
    RETURNING etl_run_log.run_id INTO v_run;

    -- 01
    v_t0 := clock_timestamp();
    SELECT format('городов %s, людей %s, замечаний %s', b.cities, b.persons, b.issues)
      INTO v_res FROM core.step_01_build_refs() b;
    PERFORM core.fn_log_step(v_run, 1, 'step_01_build_refs', v_res, v_t0);

    -- 02
    v_t0 := clock_timestamp();
    v_n := core.step_02_stage_raw();
    ANALYZE core.stg_raw_row;           -- ускоряет шаг 03
    PERFORM core.fn_log_step(v_run, 2, 'step_02_stage_raw', format('строк RAW %s', v_n), v_t0);

    -- 03
    v_t0 := clock_timestamp();
    v_n := core.step_03_clean_events();
    ANALYZE core.stg_event_clean;
    PERFORM core.fn_log_step(v_run, 3, 'step_03_clean_events', format('разобрано строк %s', v_n), v_t0);

    -- 04
    v_t0 := clock_timestamp();
    v_n := core.step_04_quarantine();
    PERFORM core.fn_log_step(v_run, 4, 'step_04_quarantine', format('в карантине %s', v_n), v_t0);

    -- 05
    v_t0 := clock_timestamp();
    CALL core.step_05_load_core();
    SELECT format('посылок %s, событий %s', (SELECT count(*) FROM core.shipment),
                                              (SELECT count(*) FROM core.shipment_event))
      INTO v_res;
    PERFORM core.fn_log_step(v_run, 5, 'step_05_load_core', v_res, v_t0);

    -- 06
    v_t0 := clock_timestamp();
    v_n := core.step_06_build_marts();
    PERFORM core.fn_log_step(v_run, 6, 'step_06_build_marts', format('mart_shipment %s строк', v_n), v_t0);

    -- 07
    v_t0 := clock_timestamp();
    v_fail := core.step_07_quality_checks(v_run);
    SELECT count(*) INTO v_warn FROM core.dq_check_result d
     WHERE d.run_id = v_run AND d.check_level = 'WARNING' AND NOT d.passed;
    PERFORM core.fn_log_step(v_run, 7, 'step_07_quality_checks',
                             format('ERROR не пройдено %s, WARNING %s', v_fail, v_warn), v_t0);

    -- Итог запуска
    UPDATE core.etl_run_log l
       SET finished_at      = clock_timestamp(),
           status           = CASE WHEN v_fail = 0 THEN 'SUCCESS' ELSE 'CHECKS_FAILED' END,
           raw_rows         = s.raw_total,
           rows_loaded      = s.loaded,
           rows_quarantined = s.quarantined,
           rows_duplicated  = s.duplicates,
           rows_unaccounted = s.unaccounted,
           checks_failed    = v_fail,
           checks_warned    = v_warn
      FROM core.v_raw_processing_stats s
     WHERE l.run_id = v_run;

    RETURN QUERY
    SELECT s.run_id, s.step_no, s.step_name, s.result, s.seconds
      FROM core.run_step_log s
     WHERE s.run_id = v_run
     ORDER BY s.step_no;
END;
$$;
