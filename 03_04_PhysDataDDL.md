# Физическая модель и DLL

Данный документ, поскольку этапы 3 и 4 являются по сути сильносвязными продолжениями друг друга, реализует сразу две поставленные задачи:

* разработка физической модели (или, по другому, целевая ER-диаграмма данных): "*После обследования отрисовать целевую ER-схему хранилища в pgModeler либо другом ER-инструменте. Схема должна отражать таблицы, ключи и связи.*";
* разработка SQL DDL: "*Реализовать целевую модель в схеме core. Составные RAW-поля разобрать; повторяющиеся сущности выделить.*".

## Физическая модель

На основе представленных анализов сырых данных [здесь](./01_профилирование.md) и [здесь](./02_модель_и_правила.md), где уже есть полноценное описание модели "сущность-связь" (она же: логическая ER-диаграмма), предлагается следующая полноценная физическая модель.

Для начала, чтобы вспомнить, логическая модель данных из анализа:

```mermaid
erDiagram
    CITY {
        smallint  city_id            PK
        text      city_name          UK
    }

    PERSON {
        smallint  person_id          PK
        text      person_code        UK
        text      last_name
        text      first_name
        text      patronymic
        smallint  city_id            FK
    }

    ROUTE {
        smallint  route_id           PK
        smallint  from_city_id       FK
        smallint  to_city_id         FK
    }

    EVENT_STATUS {
        smallint  status_id          PK
        text      status_code        UK
        text      status_name
        smallint  seq_no
        boolean   is_terminal
    }

    SHIPMENT {
        text      shipment_id        PK
        smallint  sender_person_id   FK
        smallint  receiver_person_id FK
        smallint  route_id           FK
        smallint  courier_person_id  FK
    }

    SHIPMENT_EVENT {
        bigint    event_id           PK
        text      shipment_id        FK
        timestamp event_datetime
        smallint  status_id          FK
    }

    CITY         ||--o{ PERSON         : "место жительства"
    CITY         ||--o{ ROUTE          : "откуда"
    CITY         ||--o{ ROUTE          : "куда"
    PERSON       ||--o{ SHIPMENT       : "отправитель"
    PERSON       ||--o{ SHIPMENT       : "получатель"
    PERSON       ||--o{ SHIPMENT       : "назначенный курьер"
    ROUTE        ||--o{ SHIPMENT       : "направление"
    SHIPMENT     ||--|{ SHIPMENT_EVENT : "состоит из 5 событий"
    EVENT_STATUS ||--o{ SHIPMENT_EVENT : "тип события"
```

Также нам понадобится набор некоторых служебных таблиц из тех же документов с анализом:

* `stg_raw_row` — снимок RAW: одна строка = одна строка `public.raw_data_06` со стабильным `raw_row_id` (хеш 7 полей + номер повтора);
* `stg_event_clean` — разобранные и стандартизованные поля каждой строки RAW, причины карантина и флаги качества;
* `quarantine` — очередь карантина: исходная строка (`payload`), причины, статус ручной обработки;
* `raw_row_outcome` — итог каждой строки RAW: LOAD / QUARANTINE / DUPLICATE;
* `etl_run_log` — журнал запусков pipeline (создаётся в `sql/08_quality_control.sql`);
* `event_quality_flag` — флаги качества событий;
* `shipment_quality_flag` — флаги качества посылок.

`shipment_event.raw_hash` хранит `raw_row_id` строки RAW (FK14 → `stg_raw_row.raw_row_id`) и уникален (K9):
одна строка RAW даёт не больше одного события, точные дубли событий не создают.

```mermaid
erDiagram
    ETL_RUN_LOG {
        int       run_id             PK
        timestamp started_at
        timestamp finished_at
        int       rows_read
        int       rows_duplicated
        int       rows_quarantined
        int       rows_loaded
    }

    STG_EVENT_CLEAN {
        text      raw_row_id         FK
        bool      is_exact_duplicate
        text      duplicate_of
        timestamp event_ts
        text      status_code
        int       status_seq
        int       sender_no
        text      sender_city
        int       receiver_no
        text      receiver_city
        int       courier_no
        text      route_from
        text      route_to
    }

    STG_RAW_ROW {
        text      raw_row_id         PK
        text      raw_hash
        int       occurrence
        bool      is_exact_duplicate
        text      shipment_id
        text      event_datetime
        text      sender_info
        text      route_info
        text      courier_info
        text      status_info
    }

    QUARANTINE {
        text      raw_row_id         PK
        text      source_table
        text      primary_reason
        text      reason_codes
        text      reason_detail
        jsonb     payload
        jsonb     suggested_fix
        bool      is_active
        timestamp first_detected_at
        text      resolution_status
        text      resolution_comment
        timestamp resolved_at
        timestamp deactivated_at
    }

    SHIPMENT_EVENT {
        bigint    event_id           PK
        text      shipment_id        FK
        timestamp event_datetime
        int       status_id          FK
        text      raw_hash           FK "UNIQUE, = raw_row_id"
    }

    SHIPMENT {
        text      shipment_id        PK
    }

    EVENT_QUALITY_FLAG {
        bigint    event_id           FK
        text      flag_code
    }

    SHIPMENT_QUALITY_FLAG {
        text      shipment_id        FK
        text      flag_code
    }

    STG_RAW_ROW    ||--o| STG_EVENT_CLEAN       : ""
    STG_RAW_ROW    ||--o| SHIPMENT_EVENT        : ""
    SHIPMENT_EVENT ||--o{ EVENT_QUALITY_FLAG    : ""
    SHIPMENT       ||--o{ SHIPMENT_QUALITY_FLAG : ""
```

Итого, общая таблица модели сущности-связи, объединяя два предыдущих:

```mermaid
erDiagram
    CITY {
        smallint  city_id            PK
        text      city_name          UK
    }

    PERSON {
        smallint  person_id          PK
        text      person_code        UK
        text      last_name
        text      first_name
        text      patronymic
        smallint  city_id            FK
    }

    ROUTE {
        smallint  route_id           PK
        smallint  from_city_id       FK
        smallint  to_city_id         FK
    }

    EVENT_STATUS {
        smallint  status_id          PK
        text      status_code        UK
        text      status_name
        smallint  seq_no
        boolean   is_terminal
    }

    SHIPMENT {
        text      shipment_id        PK
        smallint  sender_person_id   FK
        smallint  receiver_person_id FK
        smallint  route_id           FK
        smallint  courier_person_id  FK
    }

    SHIPMENT_EVENT {
        bigint    event_id           PK
        text      shipment_id        FK
        timestamp event_datetime
        smallint  status_id          FK
    }

    ETL_RUN_LOG {
        int       run_id             PK
        timestamp started_at
        timestamp finished_at
        int       rows_read
        int       rows_duplicated
        int       rows_quarantined
        int       rows_loaded
    }

    STG_EVENT_CLEAN {
        text      raw_row_id         FK
        bool      is_exact_duplicate
        text      duplicate_of
        timestamp event_ts
        text      status_code
        int       status_seq
        int       sender_no
        text      sender_city
        int       receiver_no
        text      receiver_city
        int       courier_no
        text      route_from
        text      route_to
    }

    STG_RAW_ROW {
        text      raw_row_id         PK
        text      raw_hash
        int       occurrence
        bool      is_exact_duplicate
        text      shipment_id
        text      event_datetime
        text      sender_info
        text      route_info
        text      courier_info
        text      status_info
    }

    QUARANTINE {
        text      raw_row_id         PK
        text      source_table
        text      primary_reason
        text      reason_codes
        text      reason_detail
        jsonb     payload
        jsonb     suggested_fix
        bool      is_active
        timestamp first_detected_at
        text      resolution_status
        text      resolution_comment
        timestamp resolved_at
        timestamp deactivated_at
    }

    EVENT_QUALITY_FLAG {
        bigint    event_id           FK
        text      flag_code
    }

    SHIPMENT_QUALITY_FLAG {
        text      shipment_id        FK
        text      flag_code
    }

    CITY           ||--o{ PERSON                : ""
    CITY           ||--o{ ROUTE                 : ""
    CITY           ||--o{ ROUTE                 : ""
    PERSON         ||--o{ SHIPMENT              : ""
    PERSON         ||--o{ SHIPMENT              : ""
    PERSON         ||--o{ SHIPMENT              : ""
    ROUTE          ||--o{ SHIPMENT              : ""
    SHIPMENT       ||--|{ SHIPMENT_EVENT        : ""
    EVENT_STATUS   ||--o{ SHIPMENT_EVENT        : ""
    STG_RAW_ROW    ||--o| STG_EVENT_CLEAN       : ""
    STG_RAW_ROW    ||--o| SHIPMENT_EVENT        : ""
    SHIPMENT_EVENT ||--o{ EVENT_QUALITY_FLAG    : ""
    SHIPMENT       ||--o{ SHIPMENT_QUALITY_FLAG : ""
```

Преобразования доменов:

* для основных идентификаторов было принято использовать стандартный тип `INT`;
* для таблицы с городами (**CITY** -> **Cities**) выбран стандартный тип `SMALLINT`, из-за размерностей и реального количества городов;
* для тех мест, где можно было бы выбрать стандартный тип `TINYINT` был выбран `SMALLINT`, из-за того, что некоторые реализации БД *не поддерживают* `TINYINT`.

Соответствующая физическая модель:

![Physical Model](./Task3.svg)

Некоторые примечания к "прочтению" диаграммы:

1. все атрибуты по умолчанию имеют свойство *необязательный*;
2. номера внешних ключей "глобальны" для удобства;
3. свойство `UNIQUE (Kn)` для атрибутов, где *`n`* одинаково, означает связку или составной, *не основной* (не `PRIMARY KEY`) ключ.

## SQL DDL

Вторая часть предполагает описание полученной [целевой модели](#физическая-модель) в схеме `core`. Поскольку физическая модель построена на модели сущности-связи, для которой были решены проблемы с составными полями и повторяющимися сущностями (приведена к 2-ой или 3-ей нормальной форме, если более формально), то задача это части сводится к простому написанию SQL кода, который бы создавал необходимые таблицы и связи.

Набор SQL запросов для создания основных таблиц (по запросу коллег все названия, в отличие от физической модели выше приведены к `snake_case` и к названиям из модели сущности-связи) описан в файле [`Task3.sql`](./Task3.sql).
