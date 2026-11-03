# Этап 7. Загрузка данных в core

**Команда 06 · «Доставка посылок»**

> Этап 7. Загрузить корректные данные в core. Повторный запуск pipeline должен быть идемпотентным:
> при неизменном RAW итоговые таблицы и показатели не изменяются, дубли не появляются.

## 1. Развёртывание и запуск

Все объекты — в схеме `core`. RAW (`public.raw_data_06`) только читается.

```sql
\i deploy.sql                         -- все объекты решения, можно запускать повторно
SELECT * FROM core.run_pipeline();    -- первый запуск
SELECT * FROM core.run_pipeline();    -- второй запуск
SELECT * FROM core.v_run_comparison;  -- сравнение двух запусков (см. 08_проверки_качества.md)
```

Порядок файлов в `deploy.sql`:

| Файл | Что внутри |
| :--- | :--- |
| `sql/01_parse_functions.sql` | справочники, функции разбора, `fn_build_refs()` |
| `sql/04_stage_quarantine.sql` | шаги 02–04: снимок RAW, очистка, карантин, итог строк RAW |
| `Task3.sql` | таблицы core (этапы 3–4) |
| `sql/check_core_table.sql` | `core.check_core_counts()` — сверка количеств core |
| `sql/06_load_in_core.sql` | шаг 05: загрузка core, справочник флагов `ref_quality_flag` |
| `sql/07_marts.sql` | шаг 06: витрины |
| `sql/08_quality_control.sql` | шаг 07: проверки качества, журнал запусков, представления контроля |
| `sql/09_mart_queries.sql` | контрольные запросы к витринам `core.v_q01…v_q10` |
| `sql/run_pipeline.sql` | шаг 01 и оркестратор `core.run_pipeline()` |

## 2. Оркестратор `core.run_pipeline()`

Одна функция запускает шаги строго по порядку 01 → 07 в одной транзакции и возвращает журнал шагов.

| Шаг | Функция / процедура | Что делает |
| :---: | :--- | :--- |
| 01 | `core.step_01_build_refs()` | справочники городов и людей из RAW |
| 02 | `core.step_02_stage_raw()` | снимок RAW со стабильным `raw_row_id`, точные дубли |
| 03 | `core.step_03_clean_events()` | разбор полей, причины карантина, флаги, итог строки |
| 04 | `core.step_04_quarantine()` | карантин (upsert с сохранением ручной обработки) + итог по каждой строке RAW |
| 05 | `core.step_05_load_core()` | загрузка core из строк с итогом LOAD |
| 06 | `core.step_06_build_marts()` | витрины `core.mart_*` |
| 07 | `core.step_07_quality_checks(run_id)` | проверки качества и контрольные показатели запуска |

* `pg_advisory_xact_lock` — два запуска одновременно не пойдут.
* Ошибка любого шага откатывает весь запуск: core не остаётся заполненным наполовину.
* Если не пройдена проверка уровня ERROR, данные сохраняются, а запуск получает статус `CHECKS_FAILED`.
* Каждый запуск пишется в `core.etl_run_log`, время шагов — в `core.run_step_log`.

Результат запуска:

| step_no | step_name | result | seconds |
| :---: | :--- | :--- | ---: |
| 1 | step_01_build_refs | городов 8, людей 20, замечаний 0 | 1.8 |
| 2 | step_02_stage_raw | строк RAW 10178 | 0.1 |
| 3 | step_03_clean_events | разобрано строк 10178 | 7.7 |
| 4 | step_04_quarantine | в карантине 1273 | 0.2 |
| 5 | step_05_load_core | посылок 2000, событий 8727 | 0.2 |
| 6 | step_06_build_marts | mart_shipment 2000 строк | 0.1 |
| 7 | step_07_quality_checks | ERROR не пройдено 0, WARNING 3 | 0.3 |

## 3. Правила загрузки (`core.step_05_load_core()`)

Источник — только строки `core.stg_event_clean` с итогом `LOAD`. Строки QUARANTINE и DUPLICATE в core не попадают.

| Таблица | Откуда | Ключ |
| :--- | :--- | :--- |
| `event_status` | справочник `core.ref_status` | `status_id = seq_no` (1…6), `is_terminal` — последний этап |
| `city` | справочник `core.ref_city` | номер по `city_norm` |
| `person` | справочник `core.ref_person` | `person_id` = номер из кодов S/R/C##; `person_code` = `'001'…'020'` (номера ≥ 1000 не обрезаются); ФИО в обычном написании (`initcap`), в справочнике — нижний регистр для сравнения |
| `route` | пары `route_from → route_to` строк LOAD | номер по (город отправления, город назначения) |
| `shipment` | строки LOAD, сгруппированные по посылке | `shipment_id` (`PKG-NNNNNN`) |
| `shipment_event` | каждая строка LOAD = одно событие | `event_id` — номер по (посылка, время, этап); `raw_hash` = `raw_row_id`, UNIQUE |
| `event_quality_flag` | флаги строки уровня EVENT | (событие, флаг) |
| `shipment_quality_flag` | флаги уровня SHIPMENT + вычисленные по посылке | (посылка, флаг) |

**Участники посылки.** Отправитель, получатель, курьер и маршрут внутри посылки согласованы: противоречия уже отправлены
в карантин на этапе 5 (`SHIPMENT_PARTY_CONFLICT`, `SHIPMENT_COURIER_CONFLICT`, `ROUTE_MISMATCH`). Поэтому для посылки берётся
единственное непустое значение из её строк LOAD. Курьер берётся из **любого** загружаемого события, где он указан, а не только
из «Передано курьеру»: в 110 таких событиях курьер пуст (флаг `COURIER_MISSING_ON_HANDOVER`), но указан в других строках посылки.
Итог — без курьера **66** посылок, а не 171. Согласованность проверяет `SHIPMENT_PARTY_INCONSISTENT` (этап 8).

**Нет молчаливых потерь.** Если посылку собрать нельзя (ни в одной строке LOAD нет отправителя или получателя), её события
не исчезают незаметно: проверка `LOAD_ROW_NOT_IN_CORE` даёт ошибку, и запуск получает статус `CHECKS_FAILED`. На текущих данных таких строк 0.

**Флаги качества** (справочник `core.ref_quality_flag`):

| Флаг | Уровень | Источник | Кол-во |
| :--- | :--- | :--- | ---: |
| `SENDER_EMPTY` | событие | этап 5 | 528 |
| `RECEIVER_EMPTY` | событие | этап 5 | 542 |
| `COURIER_MISSING_ON_HANDOVER` | событие | этап 5 | 110 |
| `SELF_SHIPMENT` | посылка | этап 5 | 101 |
| `SAME_CITY_DELIVERY` | посылка | этап 5 | 270 |
| `NO_COURIER` | посылка | core | 66 |
| `INCOMPLETE_CHAIN` | посылка | core | 974 |

«Доставлено» в RAW встречается только как ошибочная метка вместо базового этапа (карантин `STATUS_MISLABELED`),
поэтому полнота цепочки считается по пяти базовым этапам «Создано» … «Передано курьеру».

## 4. Идемпотентность

* Шаги 02–06 полностью пересобирают свои таблицы (`TRUNCATE` + `INSERT`) в одной транзакции.
* Все ключи детерминированы: из справочников или `row_number()` по естественному ключу, без `MAX(id) + 1` и последовательностей.
* Карантин — upsert по `raw_row_id`: статус ручной обработки (`resolution_status`, `resolution_comment`) сохраняется между запусками.
* `shipment_event.raw_hash` UNIQUE и `UNIQUE (shipment_id, event_datetime, status_id)` — повтор события невозможен.

Проверено: два запуска подряд дают одинаковые значения всех 47 контрольных показателей (количества, суммы, md5 таблиц),
см. `08_проверки_качества.md`. Тот же результат получен на чистой БД, где есть только RAW.

## 5. Результат

| Таблица core | Строк |
| :--- | ---: |
| `city` | 8 |
| `person` | 20 |
| `route` | 64 |
| `event_status` | 6 |
| `shipment` | 2 000 |
| `shipment_event` | 8 727 |
| `event_quality_flag` | 1 180 |
| `shipment_quality_flag` | 1 411 |

`core.check_core_counts()`:

| pair | core_cnt | ref_cnt | is_equal |
| :--- | ---: | ---: | :---: |
| core.city vs ref_city | 8 | 8 | true |
| core.person vs ref_person | 20 | 20 | true |
| core.shipment vs raw_data_06 (unique shipment_id) | 2000 | 2000 | true |
| core.route vs raw_data_06 (unique route combinations) | 64 | 64 | true |
| core.shipment_event vs raw_row_outcome (LOAD) | 8727 | 8727 | true |

## 6. Что исправлено относительно предыдущей версии

| Было | Стало |
| :--- | :--- |
| `run_pipeline()` падал на первом шаге: `TRUNCATE core.stg_raw_row` запрещён, пока на неё ссылается `shipment_event` (FK14) | `step_02_stage_raw()` очищает staging с `CASCADE`; core всё равно пересобирается шагом 05 |
| Шаги 02, 04, 05, 06 + отдельно `fn_build_refs()` и `run_stage_5_6()` | Шаги 01 → 07 подряд, один оркестратор; старые имена удалены |
| Справочники в пайплайне не пересобирались | Шаг 01 `step_01_build_refs()` |
| Статусы вписаны вручную в `VALUES` | Из `core.ref_status` |
| ФИО в нижнем регистре (`орлов елена`) | `Орлов Елена Ивановна` |
| `person_code` через `LPAD(…, 3)` — для номеров ≥ 1000 обрезается и даёт дубли | Длина не меньше 3, без обрезки |
| Курьер только из «Передано курьеру» — 171 посылка без курьера | Из любого события посылки — 66 |
| Посылки из всех строк stg (включая карантин); события отфильтровывались `EXISTS` молча | Только строки LOAD; потеря строки LOAD — ошибка проверки |
| `event_id = MAX + row_number()` | `row_number()` по естественному ключу |
| Флаги качества не загружались | `event_quality_flag`, `shipment_quality_flag` + справочник `ref_quality_flag`, FK `flag_code` → `ref_quality_flag` |
| Служебные таблицы без FK | FK `stg_event_clean` → `ref_status`, `quarantine` → `ref_quarantine_reason`, `raw_row_outcome` → `stg_raw_row`; справочник причин — upsert вместо `TRUNCATE` |
| Нет журнала, проверок, витрин | Этапы 8–10, см. `08_…`, `09_…`, `10_…` |
| `Task3.sql` падал на пустой БД и при повторном запуске | `CREATE TABLE IF NOT EXISTS`, порядок развёртывания в `deploy.sql`, UNIQUE (K9) на `raw_hash` |
