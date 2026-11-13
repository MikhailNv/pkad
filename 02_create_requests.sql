CREATE OR REPLACE PROCEDURE nsi.create_demo_requests(p_author varchar DEFAULT 'demo_user')
LANGUAGE plpgsql
AS $$
DECLARE
    v_update_id integer;
    v_delete_id integer;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM nsi.shipment_status
        WHERE code = 'CITY_SORTING'
    ) AND NOT EXISTS (
        SELECT 1
        FROM nsi.change_request
        WHERE operation_type = 'INSERT'
          AND new_code = 'CITY_SORTING'
    ) THEN
        INSERT INTO nsi.change_request (operation_type, new_code, new_name, author, comment)
        VALUES ('INSERT', 'CITY_SORTING', 'Сортировка в городе', p_author, 'Добавление нового статуса');
    END IF;

    SELECT status_id
    INTO v_update_id
    FROM nsi.shipment_status
    WHERE code = 'ACCEPTED';

    IF v_update_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM nsi.shipment_status
           WHERE status_id = v_update_id
             AND name = 'Принято в обработку'
       )
       AND NOT EXISTS (
           SELECT 1
           FROM nsi.change_request
           WHERE operation_type = 'UPDATE'
             AND status_id = v_update_id
             AND new_name = 'Принято в обработку'
       ) THEN
        INSERT INTO nsi.change_request (status_id, operation_type, new_name, author, comment)
        VALUES (v_update_id, 'UPDATE', 'Принято в обработку', p_author, 'Уточнение наименования статуса');
    END IF;

    SELECT status_id
    INTO v_delete_id
    FROM nsi.shipment_status
    WHERE code = 'SORTING';

    IF v_delete_id IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM nsi.shipment_status
           WHERE status_id = v_delete_id
             AND is_active = true
       )
       AND NOT EXISTS (
           SELECT 1
           FROM nsi.change_request
           WHERE operation_type = 'DELETE'
             AND status_id = v_delete_id
             AND is_applied = false
       ) THEN
        INSERT INTO nsi.change_request (status_id, operation_type, author, comment)
        VALUES (v_delete_id, 'DELETE', p_author, 'Вывод статуса из использования');
    END IF;
END;
$$;
