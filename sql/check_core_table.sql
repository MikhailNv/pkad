
CREATE OR REPLACE FUNCTION core.check_core_counts()
RETURNS TABLE (
    pair      text,
    core_cnt  bigint,
    ref_cnt   bigint,
    is_equal  boolean
)
LANGUAGE plpgsql
SET search_path = core, public
AS $function$
BEGIN
    RETURN QUERY
    WITH counts AS (
        SELECT
            (SELECT count(*) FROM core.city)     AS core_city,
            (SELECT count(*) FROM ref_city)      AS ref_city,

            (SELECT count(*) FROM core.person)   AS core_person,
            (SELECT count(*) FROM ref_person)    AS ref_person,

            (SELECT count(*) FROM core.shipment) AS core_shipment,
            (
                SELECT COUNT(DISTINCT NULLIF(regexp_replace(shipment_id, '[^0-9]', '', 'g'), ''))
                FROM public.raw_data_06
            ) AS raw_data_06_shipment,

            (SELECT count(*) FROM core.route)    AS core_route,
            (
                WITH normalized_routes AS (
                    SELECT
                        lower(regexp_replace(trim(split_part(route_norm, '|', 1)), '\s+', ' ', 'g')) AS from_city,
                        lower(regexp_replace(trim(split_part(route_norm, '|', 2)), '\s+', ' ', 'g')) AS to_city
                    FROM (
                        SELECT
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(
                                        regexp_replace(trim(route_info), '^\s*из\s+', '', 'i'),
                                        '\s+в\s+', '|', 'gi'
                                    ),
                                    '\s*->\s*', '|', 'g'
                                ),
                                '\s*/\s*', '|', 'g'
                            ) AS route_norm
                        FROM public.raw_data_06
                        WHERE route_info IS NOT NULL
                          AND trim(route_info) <> ''
                    ) t
                )
                SELECT COUNT(*)
                FROM (
                    SELECT DISTINCT from_city, to_city
                    FROM normalized_routes
                    WHERE from_city <> ''
                      AND to_city   <> ''
                ) d
            ) AS raw_data_06_route,

            (SELECT count(*) FROM core.shipment_event) AS core_shipment_event,
            (
                SELECT count(*) FILTER (WHERE outcome = 'LOAD'::text)
                FROM core.raw_row_outcome
            ) AS raw_row_outcome_loaded
    )
    SELECT 'core.city vs ref_city'                                AS pair,
           core_city          AS core_cnt,
           ref_city           AS ref_cnt,
           core_city = ref_city                                     AS is_equal
    FROM counts
    UNION ALL
    SELECT 'core.person vs ref_person',
           core_person,
           ref_person,
           core_person = ref_person
    FROM counts
    UNION ALL
    SELECT 'core.shipment vs raw_data_06 (unique shipment_id)',
           core_shipment,
           raw_data_06_shipment,
           core_shipment = raw_data_06_shipment
    FROM counts
    UNION ALL
    SELECT 'core.route vs raw_data_06 (unique route combinations)',
           core_route,
           raw_data_06_route,
           core_route = raw_data_06_route
    FROM counts
    UNION ALL
    SELECT 'core.shipment_event vs raw_row_outcome (LOAD)',
           core_shipment_event,
           raw_row_outcome_loaded,
           core_shipment_event = raw_row_outcome_loaded
    FROM counts;
END;
$function$
;
