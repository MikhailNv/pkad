CREATE SCHEMA IF NOT EXISTS nsi;

CREATE TABLE IF NOT EXISTS nsi.shipment_status (
    status_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(20) NOT NULL,
    name varchar(100) NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    valid_from date NOT NULL DEFAULT CURRENT_DATE,
    valid_to date,
    created_at timestamp NOT NULL DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT now(),
    CONSTRAINT uq_shipment_status_code UNIQUE (code),
    CONSTRAINT chk_shipment_status_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE IF NOT EXISTS nsi.change_request (
    request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status_id integer,
    operation_type varchar(10) NOT NULL,
    new_code varchar(20),
    new_name varchar(100),
    request_status varchar(10) NOT NULL DEFAULT 'NEW',
    author varchar(100) NOT NULL,
    created_at timestamp NOT NULL DEFAULT now(),
    reviewed_at timestamp,
    reviewer varchar(100),
    comment text,
    is_applied boolean NOT NULL DEFAULT false,
    applied_at timestamp,
    CONSTRAINT fk_change_request_status FOREIGN KEY (status_id) REFERENCES nsi.shipment_status (status_id),
    CONSTRAINT chk_change_request_operation CHECK (operation_type IN ('INSERT', 'UPDATE', 'DELETE')),
    CONSTRAINT chk_change_request_values CHECK (
        (operation_type = 'INSERT' AND new_code IS NOT NULL AND new_name IS NOT NULL)
        OR (operation_type = 'UPDATE' AND status_id IS NOT NULL AND (new_code IS NOT NULL OR new_name IS NOT NULL))
        OR (operation_type = 'DELETE' AND status_id IS NOT NULL)
    ),
    CONSTRAINT chk_change_request_status CHECK (request_status IN ('NEW', 'APPROVED', 'REJECTED')),
    CONSTRAINT chk_change_request_review CHECK (
        (request_status = 'NEW' AND reviewed_at IS NULL)
        OR (request_status IN ('APPROVED', 'REJECTED') AND reviewed_at IS NOT NULL)
    ),
    CONSTRAINT chk_change_request_applied CHECK (is_applied = false OR request_status = 'APPROVED')
);

CREATE INDEX IF NOT EXISTS idx_change_request_apply
    ON nsi.change_request (request_status, is_applied);

CREATE OR REPLACE RULE rl_shipment_status_no_delete AS
    ON DELETE TO nsi.shipment_status
    DO INSTEAD NOTHING;

CREATE OR REPLACE RULE rl_change_request_no_delete AS
    ON DELETE TO nsi.change_request
    DO INSTEAD NOTHING;

INSERT INTO nsi.shipment_status (code, name, is_active, valid_from, valid_to)
VALUES
    ('CREATED', 'Создано', true, DATE '2026-01-01', NULL),
    ('ACCEPTED', 'Принято', true, DATE '2026-01-01', NULL),
    ('SORTING', 'Сортировочный центр', true, DATE '2026-01-01', NULL),
    ('IN_TRANSIT', 'В пути', true, DATE '2026-01-01', NULL),
    ('HANDED_TO_COURIER', 'Передано курьеру', true, DATE '2026-01-01', NULL),
    ('DELIVERED', 'Доставлено', true, DATE '2026-01-01', NULL)
ON CONFLICT (code) DO NOTHING;
