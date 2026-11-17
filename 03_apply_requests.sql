CREATE OR REPLACE PROCEDURE nsi.apply_approved_requests()
LANGUAGE plpgsql
AS $$
DECLARE
    r record;
    v_status_id integer;
BEGIN
    FOR r IN
        SELECT *
        FROM nsi.change_request
        WHERE request_status = 'APPROVED'
          AND is_applied = false
        ORDER BY request_id
        FOR UPDATE
    LOOP
        IF r.operation_type = 'INSERT' THEN
            IF EXISTS (
                SELECT 1
                FROM nsi.shipment_status
                WHERE code = r.new_code
            ) THEN
                UPDATE nsi.change_request
                SET is_applied = true,
                    applied_at = now(),
                    comment = COALESCE(comment || '; ', '') || 'Не применена: код уже существует'
                WHERE request_id = r.request_id;
            ELSE
                INSERT INTO nsi.shipment_status (code, name, is_active, valid_from, valid_to)
                VALUES (r.new_code, r.new_name, true, CURRENT_DATE, NULL)
                RETURNING status_id INTO v_status_id;

                UPDATE nsi.change_request
                SET status_id = v_status_id,
                    is_applied = true,
                    applied_at = now()
                WHERE request_id = r.request_id;
            END IF;

        ELSIF r.operation_type = 'UPDATE' THEN
            IF r.new_code IS NOT NULL AND EXISTS (
                SELECT 1
                FROM nsi.shipment_status
                WHERE code = r.new_code
                  AND status_id <> r.status_id
            ) THEN
                UPDATE nsi.change_request
                SET is_applied = true,
                    applied_at = now(),
                    comment = COALESCE(comment || '; ', '') || 'Не применена: код уже существует'
                WHERE request_id = r.request_id;
            ELSE
                UPDATE nsi.shipment_status
                SET code = COALESCE(r.new_code, code),
                    name = COALESCE(r.new_name, name),
                    updated_at = now()
                WHERE status_id = r.status_id;

                UPDATE nsi.change_request
                SET is_applied = true,
                    applied_at = now()
                WHERE request_id = r.request_id;
            END IF;

        ELSIF r.operation_type = 'DELETE' THEN
            UPDATE nsi.shipment_status
            SET is_active = false,
                valid_to = GREATEST(CURRENT_DATE, valid_from),
                updated_at = now()
            WHERE status_id = r.status_id
              AND is_active = true;

            UPDATE nsi.change_request
            SET is_applied = true,
                applied_at = now()
            WHERE request_id = r.request_id;
        END IF;
    END LOOP;
END;
$$;
