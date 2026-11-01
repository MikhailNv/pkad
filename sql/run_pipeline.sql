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
