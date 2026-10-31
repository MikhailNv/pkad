-- Схема 'core'.
CREATE SCHEMA IF NOT EXISTS core;

-- Таблица 'Cities' в схеме 'core'.
CREATE TABLE core.city (
    city_id SMALLINT PRIMARY KEY NOT NULL, -- Cities.CityId
    city_name TEXT NOT NULL UNIQUE -- Cities.CityName, UNIQUE (K1)
);

-- Таблица 'EventStatuses' в схеме 'core'.
CREATE TABLE core.event_status (
    status_id SMALLINT PRIMARY KEY NOT NULL, -- EventStatuses.EventStatusId
    status_code TEXT NOT NULL UNIQUE, -- -- EventStatuses.EventStatusCode UNIQUE (K4)
    status_name TEXT NOT NULL UNIQUE, -- -- EventStatuses.EventStatusName UNIQUE (K5)
    seq_no SMALLINT NOT NULL UNIQUE, -- -- EventStatuses.EventStatusSeqNo UNIQUE (K7)
    is_terminal BOOLEAN NOT NULL -- EventStatuses.EventStatusIsTerminal
);

-- Таблица 'Persons' в схеме 'core'.
CREATE TABLE core.person (
    person_id SMALLINT PRIMARY KEY NOT NULL, -- Persons.PersonId
    person_code TEXT NOT NULL UNIQUE, -- Persons.PersonCode UNIQUE (K2)
    last_name TEXT NOT NULL, -- Persons.PersonLastName
    first_name TEXT NOT NULL, -- Persons.PersonFirstName
    patronymic TEXT, -- Persons.PersonPatronymic
    city_id SMALLINT NOT NULL, -- Persons.PersonCityId
    CONSTRAINT person_K1 UNIQUE (last_name, first_name), -- UNIQUE (K8)
    CONSTRAINT person_FK1 FOREIGN KEY (city_id) REFERENCES core.city (city_id) -- FK1
);

-- Таблица 'Routes' в схеме 'core'.
CREATE TABLE core.route (
    route_id SMALLINT PRIMARY KEY NOT NULL, -- Routes.RouteId
    from_city_id SMALLINT NOT NULL, -- Routes.RouteFromCityId
    to_city_id SMALLINT NOT NULL, -- Routes.RouteToCityId
    CONSTRAINT route_K1 UNIQUE (from_city_id, to_city_id), -- UNIQUE (K3)
    CONSTRAINT route_FK1 FOREIGN KEY (from_city_id) REFERENCES core.city (city_id), -- FK2
    CONSTRAINT route_FK2 FOREIGN KEY (to_city_id) REFERENCES core.city (city_id) -- FK3
);

-- Таблица 'Shipments' в схеме 'core'.
CREATE TABLE core.shipment (
    shipment_id TEXT PRIMARY KEY NOT NULL, -- Shipments.ShipmentId
    sender_person_id SMALLINT NOT NULL, -- Shipments.ShipmentSenderPersonId
    receiver_person_id SMALLINT NOT NULL, -- Shipments.ShipmentReceiverPersonId
    courier_person_id SMALLINT, -- Shipments.ShipmentCourierPersonId
    route_id SMALLINT NOT NULL, -- Shipments.ShipmentRouteId
    CONSTRAINT shipments_FK1 FOREIGN KEY (sender_person_id) REFERENCES core.person (person_id), -- FK4
    CONSTRAINT shipments_FK2 FOREIGN KEY (receiver_person_id) REFERENCES core.person (person_id), -- FK5
    CONSTRAINT shipments_FK3 FOREIGN KEY (courier_person_id) REFERENCES core.person (person_id), -- FK6
    CONSTRAINT shipments_FK4 FOREIGN KEY (route_id) REFERENCES core.route (route_id) -- FK7
);

-- Таблица 'ShipmentQualityFlags' в схеме 'core'.
CREATE TABLE core.shipment_quality_flag (
    shipment_id TEXT NOT NULL, -- ShipmentQualityFlags.ShipmentQualityFlagShipmentId
    flag_code TEXT NOT NULL, -- ShipmentQualityFlags.ShipmentQualityFlagCode
    CONSTRAINT shipment_quality_flag_PK PRIMARY KEY (shipment_id, flag_code), -- PRIMARY KEY
    CONSTRAINT shipment_quality_flag_FK1 FOREIGN KEY (shipment_id) REFERENCES core.shipment (shipment_id) -- FK12
);

-- Таблица 'ShipmentEvents' в схеме 'core'.
CREATE TABLE core.shipment_event (
    event_id BIGINT PRIMARY KEY NOT NULL, -- ShipmentEvents.ShipmentEventId
    shipment_id TEXT NOT NULL, -- ShipmentEvents.ShipmentEventShipmentId
    event_datetime TIMESTAMP NOT NULL, -- ShipmentEvents.ShipmentEventDatetime
    status_id SMALLINT NOT NULL, -- ShipmentEvents.ShipmentEventEventStatusId
    raw_hash TEXT, -- ShipmentEvents.ShipmentEventStgRawRowRawRowId
    CONSTRAINT shipment_event_K1 UNIQUE (shipment_id, event_datetime, status_id), -- UNIQUE (K6)
    CONSTRAINT shipment_event_FK1 FOREIGN KEY (shipment_id) REFERENCES core.shipment (shipment_id), -- FK8
    CONSTRAINT shipment_event_FK2 FOREIGN KEY (status_id) REFERENCES core.event_status (status_id), -- FK9
    CONSTRAINT shipment_event_FK3 FOREIGN KEY (raw_hash) REFERENCES core.stg_raw_row (raw_row_id) -- FK14
);

-- Таблица 'EventQualityFlags' в схеме 'core'.
CREATE TABLE core.event_quality_flag (
    event_id BIGINT NOT NULL, -- EventQualityFlags.EventQualityFlagShipmentEventId
    flag_code TEXT NOT NULL, -- EventQualityFlags.EventQualityFlagCode
    CONSTRAINT event_quality_flag_PK PRIMARY KEY (event_id, flag_code), -- PRIMARY KEY
    CONSTRAINT event_quality_flag_FK1 FOREIGN KEY (event_id) REFERENCES core.shipment_event (event_id) -- FK13
);
