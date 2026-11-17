SELECT '1. Исходное состояние справочника' AS step;

SELECT status_id, code, name, is_active, valid_from, valid_to
FROM nsi.shipment_status
ORDER BY status_id;

SELECT '2. Создание демонстрационных заявок' AS step;

CALL nsi.create_demo_requests('student_ivanov');

SELECT request_id, operation_type, status_id, new_code, new_name, request_status, author, is_applied
FROM nsi.change_request
ORDER BY request_id;

SELECT '3. Утверждение заявок' AS step;

UPDATE nsi.change_request
SET request_status = 'APPROVED',
    reviewed_at = now(),
    reviewer = 'manager_petrov'
WHERE author = 'student_ivanov'
  AND request_status = 'NEW'
  AND is_applied = false;

INSERT INTO nsi.change_request (status_id, operation_type, new_name, request_status, author, created_at, reviewed_at, reviewer, comment)
SELECT s.status_id, 'UPDATE', 'Доставлено клиенту', 'REJECTED', 'student_ivanov', now(), now(), 'manager_petrov', 'Отклонено: наименование уже согласовано в другой редакции'
FROM nsi.shipment_status s
WHERE s.code = 'DELIVERED'
  AND NOT EXISTS (
      SELECT 1
      FROM nsi.change_request cr
      WHERE cr.operation_type = 'UPDATE'
        AND cr.status_id = s.status_id
        AND cr.request_status = 'REJECTED'
  );

SELECT request_id, operation_type, status_id, new_code, new_name, request_status, reviewer, is_applied
FROM nsi.change_request
ORDER BY request_id;

SELECT '4. Применение утверждённых заявок' AS step;

CALL nsi.apply_approved_requests();

SELECT '5. Состояние справочника после применения' AS step;

SELECT status_id, code, name, is_active, valid_from, valid_to, updated_at
FROM nsi.shipment_status
ORDER BY status_id;

SELECT '6. Состояние заявок после применения' AS step;

SELECT request_id, operation_type, status_id, new_code, new_name, request_status, is_applied, applied_at, comment
FROM nsi.change_request
ORDER BY request_id;

SELECT '7. Повторный запуск обработчика' AS step;

CALL nsi.apply_approved_requests();

SELECT '8. Проверка отсутствия повторного применения' AS step;

SELECT count(*) AS applied_requests
FROM nsi.change_request
WHERE is_applied = true;

SELECT count(*) AS status_rows
FROM nsi.shipment_status;

SELECT code, count(*) AS duplicates
FROM nsi.shipment_status
GROUP BY code
HAVING count(*) > 1;

SELECT '9. Итоговая проверка отклонённой заявки' AS step;

SELECT request_id, operation_type, status_id, new_name, request_status, is_applied, comment
FROM nsi.change_request
WHERE request_status = 'REJECTED'
ORDER BY request_id;

SELECT '10. Проверка запрета физического удаления' AS step;

DELETE FROM nsi.shipment_status
WHERE code = 'SORTING';

DELETE FROM nsi.change_request
WHERE request_status = 'REJECTED';

SELECT
    (SELECT count(*) FROM nsi.shipment_status) AS status_rows,
    (SELECT count(*) FROM nsi.change_request) AS request_rows;
