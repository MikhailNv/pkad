-- Покрытие функций разбора по всему RAW: сколько строк разобрано и какие ошибки
SET search_path = core, public;
WITH r AS (
    SELECT r.*,
           (fn_split_party(sender_info)).name_part   AS s_name, (fn_split_party(sender_info)).city_part   AS s_city,
           (fn_split_party(receiver_info)).name_part AS r_name, (fn_split_party(receiver_info)).city_part AS r_city
      FROM public.raw_data_06 r
),
p AS (
    SELECT (fn_parse_shipment_id(shipment_id)).err AS id_err,
           (fn_parse_ts(event_datetime)).err       AS ts_err,
           (fn_parse_status(status_info)).err      AS st_err,
           (fn_parse_route(route_info)).err        AS rt_err,
           (fn_parse_person(s_name, 'S')).err           AS sp_err,
           (fn_parse_city(s_city)).err             AS sc_err,
           (fn_parse_person(r_name, 'R')).err           AS rp_err,
           (fn_parse_city(r_city)).err             AS rc_err,
           (fn_parse_person(courier_info, 'C')).err     AS cp_err
      FROM r
)
SELECT field, coalesce(err, 'OK') AS result, count(*) AS rows
  FROM p
 CROSS JOIN LATERAL (VALUES ('1 shipment_id', id_err), ('2 event_datetime', ts_err), ('3 status', st_err),
                            ('4 route', rt_err), ('5 sender', sp_err), ('6 sender_city', sc_err),
                            ('7 receiver', rp_err), ('8 receiver_city', rc_err), ('9 courier', cp_err)) v(field, err)
 GROUP BY 1, 2
 ORDER BY 1, 3 DESC;
