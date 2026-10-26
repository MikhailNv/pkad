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

* `stg_raw_row` - журнал прибытия, куда будут записываться статусы для прибывающих и пребывающих товаров;
* `quarantine_row` - изоляция для товаров;
* `etl_run_log` - отчёт.

Введём ещё две служебные таблицы `event_quality_flag` и `shipment_quality_flag` флаги качества для событий и обозначений аномалий. Для таких данных модель сущность-связь будет выглядеть так:

```mermaid
erDiagram
    ETL_RUN_LOG {
        int       run_id           PK
        timestamp started_at
        timestamp finished_at
        int       rows_read
        int       rows_duplicated
        int       rows_quarantined
        int       rows_loaded
    }

    STG_RAW_ROW {
        text      raw_hash         PK
        int       raw_row_no
        jsonb     payload
        text      load_status
    }

    QUARANTINE_ROW {
        bigserial quarantine_id    PK
        text      raw_hash FK
        text      reason_code
        text      reason_detail
        jsonb     payload
    }

    SHIPMENT_EVENT {
        bigint    event_id PK
        text      shipment_id      FK
    }

    SHIPMENT {
        text      shipment_id      PK
    }

    EVENT_QUALITY_FLAG {
        bigint    event_id         FK
        text      flag_code
    }

    SHIPMENT_QUALITY_FLAG {
        text      shipment_id      FK
        text      flag_code
    }

    ETL_RUN_LOG    ||--o{ STG_RAW_ROW           : "обрабатывает в рамках пакета"
    STG_RAW_ROW    ||--o| QUARANTINE_ROW        : "отклоняется в карантин"
    STG_RAW_ROW    ||--o| SHIPMENT_EVENT        : "успешно загружается в факт"
    SHIPMENT_EVENT ||--o{ EVENT_QUALITY_FLAG    : "имеет замечания к событию"
    SHIPMENT       ||--o{ SHIPMENT_QUALITY_FLAG : "имеет замечания к посылке"
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

    STG_RAW_ROW {
        text      raw_hash           PK
        int       raw_row_no
        jsonb     payload
        text      load_status
    }

    QUARANTINE_ROW {
        bigserial quarantine_id      PK
        text      raw_hash FK
        text      reason_code
        text      reason_detail
        jsonb     payload
    }

    EVENT_QUALITY_FLAG {
        bigint    event_id           FK
        text      flag_code
    }

    SHIPMENT_QUALITY_FLAG {
        text      shipment_id        FK
        text      flag_code
    }

    CITY           ||--o{ PERSON                : "место жительства"
    CITY           ||--o{ ROUTE                 : "откуда"
    CITY           ||--o{ ROUTE                 : "куда"
    PERSON         ||--o{ SHIPMENT              : "отправитель"
    PERSON         ||--o{ SHIPMENT              : "получатель"
    PERSON         ||--o{ SHIPMENT              : "назначенный курьер"
    ROUTE          ||--o{ SHIPMENT              : "направление"
    SHIPMENT       ||--|{ SHIPMENT_EVENT        : "состоит из 5 событий"
    EVENT_STATUS   ||--o{ SHIPMENT_EVENT        : "тип события"
    ETL_RUN_LOG    ||--o{ STG_RAW_ROW           : "обрабатывает в рамках пакета"
    STG_RAW_ROW    ||--o| QUARANTINE_ROW        : "отклоняется в карантин"
    STG_RAW_ROW    ||--o| SHIPMENT_EVENT        : "успешно загружается в факт"
    SHIPMENT_EVENT ||--o{ EVENT_QUALITY_FLAG    : "имеет замечания к событию"
    SHIPMENT       ||--o{ SHIPMENT_QUALITY_FLAG : "имеет замечания к посылке"
```

Преобразования доменов:

* для основных идентификаторов было принято использовать стандартный тип `INT`;
* для таблицы с городами (**CITY** -> **Cities**) выбран стандартный тип `SMALLINT`, из-за размерностей и реального количества городов;
* для некоторых идентификаторов-кодов был выбран тип `CHAR(...)`, который устанавливает статический размер строки в БД, - здесь следует смотреть на [п. 4 анализа](./02_модель_и_правила.md#4-словарь-данных-атрибуты-типы-ключи-ограничения);
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
