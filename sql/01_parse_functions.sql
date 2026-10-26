-- =====================================================================
-- Этап 5. Функции разбора и очистки полей RAW
-- Команда 06 · «Доставка посылок»
--
-- Принципы:
--   * функции не бросают исключений на «грязных» значениях:
--     возвращают значение + код ошибки (err), err IS NULL = разобрано;
--   * лучше отправить в карантин, чем «угадать»: принимаются только формы,
--     которые разбираются однозначно;
--   * справочники (люди, города) строятся из RAW, жёстко заданы только
--     бизнес-словари: статусы, заглушки, месяцы, сокращения городов;
--   * скрипт перезапускаемый.
--
-- Что проверяется не здесь, а на этапе 6 (уровень записи, а не поля):
--   дата вне бизнес-периода, маршрут ≠ города отправителя/получателя,
--   «Доставлено» вместо базового статуса, дубли.
--
-- «Числа и суммы» из ТЗ: в RAW команды 06 числовых полей и сумм нет.
-- Числовые значения — это цифры ID посылки, номер кода S/R/C## и
-- компоненты даты/времени; все они приводятся к int с проверкой диапазона.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;
SET search_path = core, public;

-- ---------------------------------------------------------------------
-- Словари
-- ---------------------------------------------------------------------

-- Текстовые заглушки вместо NULL (сравнение со всем значением целиком, нижний регистр)
CREATE TABLE IF NOT EXISTS ref_placeholder (
    value_norm text PRIMARY KEY
);
INSERT INTO ref_placeholder (value_norm) VALUES
    ('null'), ('none'), ('nan'), ('n/a'), ('-'), ('—'), ('?'), ('??'), ('???'),
    ('неизвестно'), ('не известно'), ('не указан'), ('не указана'), ('не указано'),
    ('нет'), ('нет данных'), ('пусто')
ON CONFLICT DO NOTHING;

-- Статусы жизненного цикла (бизнес-справочник)
CREATE TABLE IF NOT EXISTS ref_status (
    status_code text PRIMARY KEY,
    status_name text NOT NULL UNIQUE,
    seq_no      smallint NOT NULL UNIQUE
);
INSERT INTO ref_status VALUES
    ('CREATED',           'Создано',             1),
    ('ACCEPTED',          'Принято',             2),
    ('SORTING',           'Сортировочный центр', 3),
    ('IN_TRANSIT',        'В пути',              4),
    ('HANDED_TO_COURIER', 'Передано курьеру',    5),
    ('DELIVERED',         'Доставлено',          6)
ON CONFLICT DO NOTHING;

-- Написания статусов → код (нормализованные: нижний регистр, ё→е, один пробел)
CREATE TABLE IF NOT EXISTS ref_status_alias (
    alias_norm  text PRIMARY KEY,
    status_code text NOT NULL REFERENCES ref_status
);
INSERT INTO ref_status_alias
SELECT replace(lower(status_name), 'ё', 'е'), status_code FROM ref_status
ON CONFLICT DO NOTHING;

-- Названия месяцев (англ. и рус., полные и сокращённые)
CREATE TABLE IF NOT EXISTS ref_month (
    alias    text PRIMARY KEY,
    month_no smallint NOT NULL CHECK (month_no BETWEEN 1 AND 12)
);
INSERT INTO ref_month VALUES
    ('jan',1),('feb',2),('mar',3),('apr',4),('may',5),('jun',6),
    ('jul',7),('aug',8),('sep',9),('sept',9),('oct',10),('nov',11),('dec',12),
    ('january',1),('february',2),('march',3),('april',4),('june',6),('july',7),
    ('august',8),('september',9),('october',10),('november',11),('december',12),
    ('янв',1),('фев',2),('мар',3),('апр',4),('мая',5),('май',5),('июн',6),
    ('июл',7),('авг',8),('сен',9),('сент',9),('окт',10),('ноя',11),('дек',12),
    ('января',1),('февраля',2),('марта',3),('апреля',4),('июня',6),('июля',7),
    ('августа',8),('сентября',9),('октября',10),('ноября',11),('декабря',12)
ON CONFLICT DO NOTHING;

-- Сокращения городов → каноническое название
CREATE TABLE IF NOT EXISTS ref_city_alias (
    alias_norm text PRIMARY KEY,
    city_name  text NOT NULL
);
INSERT INTO ref_city_alias VALUES
    ('спб', 'Санкт-Петербург'), ('с-пб', 'Санкт-Петербург'), ('питер', 'Санкт-Петербург'),
    ('мск', 'Москва'), ('екб', 'Екатеринбург'), ('нск', 'Новосибирск')
ON CONFLICT DO NOTHING;

-- Справочники из данных: полностью пересобираются fn_build_refs()
DROP TABLE IF EXISTS ref_person;
DROP TABLE IF EXISTS ref_city;

CREATE TABLE ref_city (
    city_norm text PRIMARY KEY,          -- lower(), ё→е, без «г.»
    city_name text NOT NULL UNIQUE       -- самое частое написание в RAW (без «г.»)
);

CREATE TABLE ref_person (
    person_no  int  PRIMARY KEY,         -- номер из кодов S/R/C##; без кода — 1000+
    last_name  text NOT NULL,            -- нижний регистр, ё→е
    first_name text NOT NULL,
    patronymic text NOT NULL,
    city_name  text,
    UNIQUE (last_name, first_name, patronymic)
);

-- Что не попало в справочники и почему (опечатки, конфликты кодов)
CREATE TABLE IF NOT EXISTS ref_build_issue (
    ref_name text NOT NULL,
    issue    text NOT NULL,
    detail   text NOT NULL
);

-- ---------------------------------------------------------------------
-- Общая нормализация текста
-- ---------------------------------------------------------------------

-- Пробельные символы: невидимые (zero-width, BOM) удаляем,
-- все виды пробелов (NBSP, тонкие, табы, переводы строк) → один пробел, trim
CREATE OR REPLACE FUNCTION fn_clean_ws(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
               regexp_replace(coalesce(p, ''), '[​-‍⁠﻿]', '', 'g'),
               '[\s  -   　]+', ' ', 'g'))
$$;

-- Пробелы + заглушки → NULL
CREATE OR REPLACE FUNCTION fn_norm_text(p text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN v = '' THEN NULL
             WHEN EXISTS (SELECT 1 FROM core.ref_placeholder WHERE value_norm = lower(v)) THEN NULL
             ELSE v
           END
    FROM (SELECT core.fn_clean_ws(p) AS v) s
$$;

-- ---------------------------------------------------------------------
-- Идентификатор посылки: PKG-900001 / № PKG 900001 / 900001 → PKG-900001
-- Принимается одна форма: [№|#|N°] [PKG|ПОСЫЛКА] [разделитель] ровно 6 цифр.
-- Ошибки: ID_EMPTY, ID_INVALID
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_parse_shipment_id(p text, OUT shipment_id text, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v text := upper(core.fn_norm_text(p));
    m text[];
BEGIN
    IF v IS NULL THEN err := 'ID_EMPTY'; RETURN; END IF;
    m := regexp_match(v, '^(?:(?:№|#|N°)\s*)?(?:PKG|ПОСЫЛКА)?[\s\-–—_]*(\d{6})$');
    IF m IS NULL THEN err := 'ID_INVALID'; RETURN; END IF;
    shipment_id := 'PKG-' || m[1];
END $$;

-- ---------------------------------------------------------------------
-- Дата и время. Поддерживаются:
--   DD.MM.YYYY / DD/MM/YYYY / DD-MM-YYYY, в т.ч. двузначный год (20YY)
--   YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD, разделитель даты и времени ' ' или 'T'
--   YYYYMMDD HHMI[SS]
--   DD Mon YYYY (англ./рус. названия месяцев)
--   время HH:MI[:SS], опционально AM/PM, опционально предлог «в»
-- Порядок день/месяц для форматов с точкой и слешем — DD/MM: в RAW нет ни одной
-- даты с месяцем > 12, а неоднозначные подтверждаются шагом 8 ч (тест в 03_tests.sql).
-- Ошибки: DT_EMPTY, DT_PLACEHOLDER, DT_RELATIVE, DT_UNKNOWN_FORMAT,
--         DT_NO_TIME, DT_INVALID_DATE, DT_INVALID_TIME
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_parse_ts(p text, OUT ts timestamp, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    raw_v text := core.fn_clean_ws(p);
    v     text;
    m     text[];
    y int; mo int; d int; hh int; mi int; ss int := 0;
    t_part text; mer text;
BEGIN
    IF raw_v = '' THEN err := 'DT_EMPTY'; RETURN; END IF;
    IF core.fn_norm_text(raw_v) IS NULL THEN err := 'DT_PLACEHOLDER'; RETURN; END IF;
    -- относительная дата: слово-указатель и нет явной даты
    IF lower(raw_v) ~ '\m(сегодня|вчера|завтра|позавчера|утром|вечером|днем|днём|ночью|today|yesterday|tomorrow)\M'
       AND raw_v !~ '\d{1,4}[-./]\d{1,2}|\d{8}|\d{1,2}\s+[A-Za-zА-Яа-яЁё]{3,}\.?\s+\d{4}' THEN
        err := 'DT_RELATIVE'; RETURN;
    END IF;

    -- единый вид: верхний регистр, 'T' и предлог «в» перед временем → пробел
    v := upper(raw_v);
    v := regexp_replace(v, '(\d)T(\d)', '\1 \2');
    v := regexp_replace(v, '\s+В\s+', ' ', 'g');

    -- 1) компактный YYYYMMDD HHMI[SS]
    m := regexp_match(v, '^(\d{4})(\d{2})(\d{2})(?:\s+(\d{2})(\d{2})(\d{2})?)?$');
    IF m IS NOT NULL THEN
        y := m[1]::int; mo := m[2]::int; d := m[3]::int;
        IF m[4] IS NULL THEN err := 'DT_NO_TIME'; RETURN; END IF;
        hh := m[4]::int; mi := m[5]::int; ss := coalesce(m[6]::int, 0);
    ELSE
        -- 2) YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD
        m := regexp_match(v, '^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:\s+(.*))?$');
        IF m IS NOT NULL THEN
            y := m[1]::int; mo := m[2]::int; d := m[3]::int; t_part := m[4];
        ELSE
            -- 3) DD.MM.YYYY / DD/MM/YYYY / DD-MM-YYYY / DD.MM.YY
            m := regexp_match(v, '^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?:\s+(.*))?$');
            IF m IS NOT NULL THEN
                d := m[1]::int; mo := m[2]::int;
                y := CASE WHEN length(m[3]) = 2 THEN 2000 + m[3]::int ELSE m[3]::int END;
                t_part := m[4];
            ELSE
                -- 4) DD Mon YYYY
                m := regexp_match(v, '^(\d{1,2})\s+([A-ZА-ЯЁ]+)\.?,?\s+(\d{4})(?:\s+(.*))?$');
                IF m IS NULL THEN err := 'DT_UNKNOWN_FORMAT'; RETURN; END IF;
                SELECT month_no INTO mo FROM core.ref_month WHERE alias = lower(m[2]);
                IF mo IS NULL THEN err := 'DT_UNKNOWN_FORMAT'; RETURN; END IF;
                d := m[1]::int; y := m[3]::int; t_part := m[4];
            END IF;
        END IF;

        IF t_part IS NULL OR t_part = '' THEN err := 'DT_NO_TIME'; RETURN; END IF;
        m := regexp_match(t_part, '^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$');
        IF m IS NULL THEN err := 'DT_UNKNOWN_FORMAT'; RETURN; END IF;
        hh := m[1]::int; mi := m[2]::int; ss := coalesce(m[3]::int, 0); mer := m[4];
        IF mer IS NOT NULL THEN
            IF hh NOT BETWEEN 1 AND 12 THEN err := 'DT_INVALID_TIME'; RETURN; END IF;
            hh := CASE WHEN mer = 'AM' THEN hh % 12 ELSE hh % 12 + 12 END;
        END IF;
    END IF;

    -- календарная проверка по шагам: make_date вызывается только на допустимых y/mo
    IF y < 1 OR mo NOT BETWEEN 1 AND 12 OR d < 1 THEN
        err := 'DT_INVALID_DATE'; RETURN;
    END IF;
    IF d > extract(day FROM make_date(y, mo, 1) + interval '1 month - 1 day') THEN
        err := 'DT_INVALID_DATE'; RETURN;
    END IF;
    IF hh NOT BETWEEN 0 AND 23 OR mi NOT BETWEEN 0 AND 59 OR ss NOT BETWEEN 0 AND 59 THEN
        err := 'DT_INVALID_TIME'; RETURN;
    END IF;
    ts := make_timestamp(y, mo, d, hh, mi, ss);
END $$;

-- ---------------------------------------------------------------------
-- Статус: регистр, ё, лишние пробелы, точка в конце → код из ref_status_alias
-- Ошибки: STATUS_EMPTY, STATUS_PLACEHOLDER, STATUS_UNKNOWN
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_parse_status(p text, OUT status_code text, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v text;
BEGIN
    IF core.fn_clean_ws(p) = '' THEN err := 'STATUS_EMPTY'; RETURN; END IF;
    v := core.fn_norm_text(p);
    IF v IS NULL THEN err := 'STATUS_PLACEHOLDER'; RETURN; END IF;
    v := btrim(replace(lower(v), 'ё', 'е'), ' .');
    SELECT a.status_code INTO status_code FROM core.ref_status_alias a WHERE a.alias_norm = v;
    IF status_code IS NULL THEN err := 'STATUS_UNKNOWN'; END IF;
END $$;

-- ---------------------------------------------------------------------
-- Город: trim, префикс «г.», регистр, сокращения → каноническое имя из ref_city
-- Ошибки: CITY_EMPTY, CITY_UNKNOWN
-- ---------------------------------------------------------------------

-- Написание без префикса «г.» / «город»
CREATE OR REPLACE FUNCTION fn_city_strip(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT core.fn_clean_ws(regexp_replace(core.fn_clean_ws(p), '^(г\.|г\s|город\s)\s*', '', 'i'))
$$;

-- Ключ сравнения: без префикса, нижний регистр, ё→е
CREATE OR REPLACE FUNCTION fn_city_norm_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(lower(core.fn_city_strip(p)), 'ё', 'е')
$$;

CREATE OR REPLACE FUNCTION fn_parse_city(p text, OUT city_name text, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    k text;
BEGIN
    IF core.fn_norm_text(p) IS NULL THEN err := 'CITY_EMPTY'; RETURN; END IF;
    k := core.fn_city_norm_key(p);
    SELECT c.city_name INTO city_name FROM core.ref_city c WHERE c.city_norm = k;
    IF city_name IS NULL THEN
        SELECT a.city_name INTO city_name FROM core.ref_city_alias a WHERE a.alias_norm = k;
    END IF;
    IF city_name IS NULL THEN err := 'CITY_UNKNOWN'; END IF;
END $$;

-- ---------------------------------------------------------------------
-- Маршрут: «из A в B» / «A -> B» / «A → B» / «A - B» / «A/B»
-- Сверка с городами участников — на этапе 6 (ROUTE_MISMATCH).
-- Ошибки: ROUTE_EMPTY, ROUTE_FORMAT, ROUTE_CITY_UNKNOWN
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_parse_route(p text, OUT from_city text, OUT to_city text, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v text := core.fn_norm_text(p);
    m text[];
BEGIN
    IF v IS NULL THEN err := 'ROUTE_EMPTY'; RETURN; END IF;
    m := regexp_match(v, '^из\s+(.+)\s+в\s+(.+)$', 'i');
    IF m IS NULL THEN m := regexp_match(v, '^(.+?)\s*(?:->|→|=>)\s*(.+)$'); END IF;
    IF m IS NULL THEN m := regexp_match(v, '^(.+?)\s+[-–—]\s+(.+)$'); END IF;
    IF m IS NULL THEN m := regexp_match(v, '^([^/]+)/([^/]+)$'); END IF;
    IF m IS NULL THEN err := 'ROUTE_FORMAT'; RETURN; END IF;
    from_city := (core.fn_parse_city(m[1])).city_name;
    to_city   := (core.fn_parse_city(m[2])).city_name;
    IF from_city IS NULL OR to_city IS NULL THEN
        from_city := NULL; to_city := NULL; err := 'ROUTE_CITY_UNKNOWN';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Участник «<ФИО> / <Город>»: делим по последнему «/»
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_split_party(p text, OUT name_part text, OUT city_part text)
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN m IS NULL THEN p ELSE m[1] END,
           m[2]
    FROM (SELECT regexp_match(coalesce(p, ''), '^(.*)/([^/]*)$') AS m) s
$$;

-- ---------------------------------------------------------------------
-- Код участника S/R/C## в любом обрамлении: «S3 », «[S3]», «(S3)», «ВолковS3», «s3_…».
-- Номер без ведущих нулей, 1–3 цифры; перед кодом не латиница и не цифра.
-- Группы: 1 — буква роли, 2 — номер.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_code_pattern()
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT '(?<![A-Za-z0-9])[\[\(]?([SRCsrc])([1-9][0-9]{0,2})(?![0-9])[\]\)]?'::text
$$;

-- ---------------------------------------------------------------------
-- ФИО (уже без кода) → массив токенов:
--   нижний регистр, ё→е, цифра 0 между кириллическими буквами → «о»,
--   всё, кроме кириллицы, точки и дефиса → пробел («,» и «_» тоже),
--   разлепить инициалы («а.иванов» → «а.», «иванов»), дефисы по краям токена срезать
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_name_tokens(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(array_agg(tok ORDER BY ord) FILTER (WHERE tok ~ '[а-я]'), '{}')
    FROM (
        SELECT btrim(t, '-') AS tok, ord
        FROM regexp_split_to_table(
               regexp_replace(
                 regexp_replace(
                   regexp_replace(replace(lower(coalesce(p, '')), 'ё', 'е'),
                                  '(?<=[а-я])0|0(?=[а-я])', 'о', 'g'),
                   '[^а-я.\-]+', ' ', 'g'),
                 '\.', '. ', 'g'),
               '\s+') WITH ORDINALITY AS x(t, ord)
    ) s
$$;

-- ---------------------------------------------------------------------
-- ФИО → человек из ref_person. Принимаются только однозначные формы:
--   фамилия словом + имя/отчество словами (порядок слов не важен) или инициалами
--   (инициалы — по порядку: сначала имя, потом отчество)
--     («Иванов Алексей», «Алексей Иванов», «Иванов А.А.», «А.А. Иванов», «Иванов»);
--   имя словом + инициал фамилии («Роман К.»).
-- Не больше 3 частей, без повторов, отчество словом — только вместе с именем.
-- Берём, только если подходит ровно один человек. Код S/R/C## сверяется с ним.
-- p_role ('S' | 'R' | 'C') — какая буква кода ожидается в этом поле.
-- Одиночная фамилия резолвится, если её носитель в справочнике один.
-- Ошибки: PERSON_EMPTY        — пусто / «не указан» (флаг, не карантин)
--         PERSON_CODE_ONLY    — есть только код, имени нет
--         PERSON_INVALID      — латиница, цифры, посторонние символы в имени
--         PERSON_UNKNOWN      — форма не распознана или человека нет в справочнике
--         PERSON_AMBIGUOUS    — подходят несколько человек
--         PERSON_CODE_CONFLICT, PERSON_ROLE_MISMATCH
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_parse_person(text);
CREATE OR REPLACE FUNCTION fn_parse_person(p text, p_role text DEFAULT NULL,
    OUT person_no int, OUT last_name text, OUT first_name text, OUT patronymic text,
    OUT role_code text, OUT err text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v       text := core.fn_norm_text(p);
    codes   text[];
    rest    text;
    words   text[];
    inits   text[];
    n_match int;
    m_no    int;
BEGIN
    IF v IS NULL THEN err := 'PERSON_EMPTY'; RETURN; END IF;

    -- коды: больше одного разного — конфликт
    SELECT array_agg(DISTINCT upper(m[1]) || m[2]) INTO codes
      FROM regexp_matches(v, core.fn_code_pattern(), 'g') AS m;
    IF cardinality(codes) > 1 THEN err := 'PERSON_CODE_CONFLICT'; RETURN; END IF;
    role_code := codes[1];
    IF role_code IS NOT NULL AND p_role IS NOT NULL AND left(role_code, 1) <> upper(p_role) THEN
        err := 'PERSON_ROLE_MISMATCH'; RETURN;
    END IF;

    -- остаток без кода
    rest := core.fn_norm_text(
              btrim(core.fn_clean_ws(regexp_replace(v, core.fn_code_pattern(), ' ', 'g')),
                    ' ,;:_-()[]'));
    IF rest IS NULL THEN
        err := CASE WHEN role_code IS NULL THEN 'PERSON_EMPTY' ELSE 'PERSON_CODE_ONLY' END;
        RETURN;
    END IF;
    -- белый список: кириллица, пробел, точка, запятая, подчёркивание, дефис
    -- (0 допускается только внутри слова — как замена буквы «о»)
    IF regexp_replace(lower(rest), '(?<=[а-яё])0|0(?=[а-яё])', 'о', 'g') !~ '^[а-яё .,_\-]+$' THEN
        err := 'PERSON_INVALID'; RETURN;
    END IF;

    SELECT coalesce(array_agg(t ORDER BY o) FILTER (WHERE t !~ '^[а-я]\.?$'), '{}'),
           coalesce(array_agg(left(t, 1) ORDER BY o) FILTER (WHERE t ~ '^[а-я]\.?$'), '{}')
      INTO words, inits
      FROM unnest(core.fn_name_tokens(rest)) WITH ORDINALITY AS u(t, o);

    IF cardinality(words) = 0
       OR cardinality(words) + cardinality(inits) > 3
       OR cardinality(words) <> (SELECT count(DISTINCT w) FROM unnest(words) AS w) THEN
        err := 'PERSON_UNKNOWN'; RETURN;
    END IF;

    SELECT count(*), min(r.person_no)
      INTO n_match, m_no
      FROM core.ref_person r
     WHERE words <@ ARRAY[r.last_name, r.first_name, r.patronymic]
       AND (NOT r.patronymic = ANY(words) OR r.first_name = ANY(words))
       AND (
             -- фамилия словом; инициалы — первые буквы недостающих имени и отчества, по порядку
             (r.last_name = ANY(words)
              AND inits = ((SELECT coalesce(array_agg(left(x, 1) ORDER BY o), '{}')
                              FROM unnest(ARRAY[r.first_name, r.patronymic]) WITH ORDINALITY AS z(x, o)
                             WHERE NOT x = ANY(words)))[1:cardinality(inits)])
             -- «Роман К.»: имя словом + инициал фамилии
          OR (words = ARRAY[r.first_name] AND inits = ARRAY[left(r.last_name, 1)])
       );

    IF n_match = 0 THEN err := 'PERSON_UNKNOWN';   RETURN; END IF;
    IF n_match > 1 THEN err := 'PERSON_AMBIGUOUS'; RETURN; END IF;
    IF role_code IS NOT NULL AND substr(role_code, 2)::int <> m_no THEN
        err := 'PERSON_CODE_CONFLICT'; RETURN;
    END IF;

    SELECT r.person_no, initcap(r.last_name), initcap(r.first_name), initcap(r.patronymic)
      INTO person_no, last_name, first_name, patronymic
      FROM core.ref_person r WHERE r.person_no = m_no;
END $$;

-- ---------------------------------------------------------------------
-- Построение справочников из RAW (полная пересборка, детерминированно)
-- ---------------------------------------------------------------------

-- Города: из частей «/ Город» отправителя и получателя.
-- Ключ, встретившийся реже c_min раз, считается опечаткой и в справочник не идёт.
CREATE OR REPLACE FUNCTION fn_build_ref_city()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    c_min CONSTANT int := 3;
    n int;
BEGIN
    DELETE FROM core.ref_city;
    DELETE FROM core.ref_build_issue WHERE ref_name = 'city';

    CREATE TEMP TABLE IF NOT EXISTS tmp_city (k text, nm text, cnt bigint) ON COMMIT DROP;
    TRUNCATE tmp_city;
    -- сокращения («СПб») сразу переводим в каноническое название
    INSERT INTO tmp_city
    SELECT core.fn_city_norm_key(coalesce(a.city_name, x.c)),
           coalesce(a.city_name, core.fn_city_strip(x.c)),
           count(*)
      FROM (SELECT (core.fn_split_party(sender_info)).city_part   AS c FROM public.raw_data_06
            UNION ALL
            SELECT (core.fn_split_party(receiver_info)).city_part FROM public.raw_data_06) x
      LEFT JOIN core.ref_city_alias a ON a.alias_norm = core.fn_city_norm_key(x.c)
     WHERE core.fn_norm_text(x.c) IS NOT NULL
     GROUP BY 1, 2;

    INSERT INTO core.ref_city (city_norm, city_name)
    SELECT DISTINCT ON (k) k, nm
      FROM tmp_city
     WHERE k IN (SELECT k FROM tmp_city GROUP BY k HAVING sum(cnt) >= c_min)
     ORDER BY k, cnt DESC, nm;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO core.ref_build_issue
    SELECT 'city', 'RARE_VALUE', k || ' (' || sum(cnt) || ' раз)'
      FROM tmp_city GROUP BY k HAVING sum(cnt) < c_min;
    RETURN n;
END $$;

-- Люди:
--   1) человек = полная форма «Фамилия Имя Отчество» (или «Имя Отчество Фамилия»),
--      встретившаяся не реже c_min раз; отчество узнаём по окончанию;
--   2) номер = код S/R/C## из строк, где код стоит рядом с фамилией и именем этого человека;
--      у человека должен быть один код, у кода — один человек, иначе в ref_build_issue;
--   3) человек без кода получает номер 1000+ (по алфавиту). Такие номера стабильны только
--      в пределах одной сборки — ключом в core должен быть (фамилия, имя, отчество);
--   4) город = самый частый город в строках с фамилией и именем этого человека.
-- Люди без отчества в RAW не попадут в справочник: их строки уйдут в карантин (PERSON_UNKNOWN).
-- Если устойчивая опечатка (≥ c_min раз) получит тот же код, что настоящий человек,
-- оба уйдут в ref_build_issue и в справочник не попадут: лучше карантин, чем угадывание.
CREATE OR REPLACE FUNCTION fn_build_ref_person()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    c_min CONSTANT int := 3;
    n int;
BEGIN
    DELETE FROM core.ref_person;
    DELETE FROM core.ref_build_issue WHERE ref_name = 'person';

    CREATE TEMP TABLE IF NOT EXISTS tmp_names (tk text[], code_no int, city_part text) ON COMMIT DROP;
    TRUNCATE tmp_names;
    INSERT INTO tmp_names
    SELECT core.fn_name_tokens(regexp_replace(name_part, core.fn_code_pattern(), ' ', 'g')),
           (regexp_match(name_part, core.fn_code_pattern()))[2]::int,
           city_part
      FROM (SELECT sp.name_part, sp.city_part
              FROM public.raw_data_06 r, core.fn_split_party(r.sender_info) sp
            UNION ALL
            SELECT rp.name_part, rp.city_part
              FROM public.raw_data_06 r, core.fn_split_party(r.receiver_info) rp
            UNION ALL
            SELECT courier_info, NULL FROM public.raw_data_06) v;

    CREATE TEMP TABLE IF NOT EXISTS tmp_person (ln text, fn text, pt text, code_no int, n_codes int, n_people int) ON COMMIT DROP;
    TRUNCATE tmp_person;
    INSERT INTO tmp_person
    WITH fio AS (
        SELECT tk, tk[3] ~ '(ич|вна|ична)$' AS pt_last, tk[2] ~ '(ич|вна|ична)$' AS pt_mid
          FROM tmp_names
         WHERE cardinality(tk) = 3 AND array_to_string(tk, ' ') !~ '\.'
    ),
    ppl AS (
        SELECT CASE WHEN pt_last THEN tk[1] ELSE tk[3] END AS ln,
               CASE WHEN pt_last THEN tk[2] ELSE tk[1] END AS fn,
               CASE WHEN pt_last THEN tk[3] ELSE tk[2] END AS pt
          FROM fio
         WHERE pt_last <> pt_mid
         GROUP BY 1, 2, 3
        HAVING count(*) >= c_min
    ),
    pc AS (
        SELECT p.ln, p.fn, p.pt, t.code_no
          FROM ppl p
          JOIN tmp_names t ON t.code_no IS NOT NULL
                          AND t.tk @> ARRAY[p.ln, p.fn] AND t.tk <@ ARRAY[p.ln, p.fn, p.pt]
         GROUP BY 1, 2, 3, 4
        HAVING count(*) >= c_min
    )
    SELECT p.ln, p.fn, p.pt, pc.code_no,
           count(pc.code_no) OVER (PARTITION BY p.ln, p.fn, p.pt),
           count(*) OVER (PARTITION BY pc.code_no)
      FROM ppl p LEFT JOIN pc USING (ln, fn, pt);

    -- полные ФИО, которые не стали человеком: редкие и с неясным отчеством
    INSERT INTO core.ref_build_issue
    SELECT 'person', 'RARE_VALUE', initcap(array_to_string(tk, ' ')) || ' (' || count(*) || ' раз)'
      FROM tmp_names
     WHERE cardinality(tk) = 3 AND array_to_string(tk, ' ') !~ '\.'
       AND (tk[3] ~ '(ич|вна|ична)$') <> (tk[2] ~ '(ич|вна|ична)$')
     GROUP BY tk HAVING count(*) < c_min
    UNION ALL
    SELECT 'person', 'PATRONYMIC_UNCLEAR', initcap(array_to_string(tk, ' ')) || ' (' || count(*) || ' раз)'
      FROM tmp_names
     WHERE cardinality(tk) = 3 AND array_to_string(tk, ' ') !~ '\.'
       AND tk[3] ~ '(ич|вна|ична)$' AND tk[2] ~ '(ич|вна|ична)$'
     GROUP BY tk;

    INSERT INTO core.ref_build_issue
    SELECT 'person',
           CASE WHEN n_codes > 1 THEN 'PERSON_MANY_CODES' ELSE 'CODE_MANY_PEOPLE' END,
           initcap(ln || ' ' || fn || ' ' || pt) || ' — код ' || code_no
      FROM tmp_person
     WHERE code_no IS NOT NULL AND (n_codes > 1 OR n_people > 1);

    INSERT INTO core.ref_person (person_no, last_name, first_name, patronymic, city_name)
    SELECT coalesce(p.code_no, 1000 + row_number() OVER (PARTITION BY p.code_no IS NULL ORDER BY p.ln, p.fn, p.pt)),
           p.ln, p.fn, p.pt,
           (SELECT c.city_name
              FROM tmp_names t, core.fn_parse_city(t.city_part) c
             WHERE t.tk @> ARRAY[p.ln, p.fn] AND c.city_name IS NOT NULL
             GROUP BY c.city_name
             ORDER BY count(*) DESC, c.city_name
             LIMIT 1)
      FROM tmp_person p
     WHERE (p.code_no IS NULL AND p.n_codes = 0)
        OR (p.code_no IS NOT NULL AND p.n_codes = 1 AND p.n_people = 1);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- Пересборка всех справочников в правильном порядке (людям нужны города)
CREATE OR REPLACE FUNCTION fn_build_refs(OUT cities int, OUT persons int, OUT issues int)
LANGUAGE plpgsql AS $$
BEGIN
    cities  := core.fn_build_ref_city();
    persons := core.fn_build_ref_person();
    SELECT count(*) INTO issues FROM core.ref_build_issue;
END $$;

-- Справочники пересоздаются в начале скрипта, поэтому сразу собираем их заново
SELECT * FROM fn_build_refs();
