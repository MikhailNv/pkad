-- Развёртывание: psql -v ON_ERROR_STOP=1 -f deploy.sql
\set ON_ERROR_STOP on
\ir sql/00_check_core.sql
\ir sql/01_parse_functions.sql
\ir sql/04_stage_quarantine.sql
\ir Task3.sql
\ir sql/check_core_table.sql
\ir sql/06_load_in_core.sql
\ir sql/07_marts.sql
\ir sql/08_quality_control.sql
\ir sql/09_mart_queries.sql
\ir sql/run_pipeline.sql
