-- БД фирмы по прокату автомобилей
-- СУБД: PostgreSQL

DROP SCHEMA IF EXISTS car_rental CASCADE;
CREATE SCHEMA car_rental;
SET search_path TO car_rental;

-- =========================
-- Справочные таблицы
-- =========================

CREATE TABLE car_category (
  category_name VARCHAR(50) PRIMARY KEY
);

CREATE TABLE fuel_type (
  fuel_name VARCHAR(30) PRIMARY KEY
);

CREATE TABLE transmission_type (
  transmission_name VARCHAR(20) PRIMARY KEY
);

CREATE TABLE payment_method (
  method_name VARCHAR(30) PRIMARY KEY
);

CREATE TABLE employee_role (
  role_name VARCHAR(50) PRIMARY KEY
);

CREATE TABLE rental_status (
  status_name VARCHAR(30) PRIMARY KEY
);

-- =========================
-- Основные таблицы
-- =========================

CREATE TABLE branch (
  branch_id BIGSERIAL PRIMARY KEY,
  branch_name VARCHAR(100) NOT NULL UNIQUE,
  city VARCHAR(60) NOT NULL,
  address VARCHAR(200) NOT NULL,
  phone VARCHAR(20)
);

CREATE TABLE employee (
  employee_id BIGSERIAL PRIMARY KEY,
  branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  role_name VARCHAR(50) NOT NULL REFERENCES employee_role(role_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(20),
  hired_at DATE NOT NULL DEFAULT CURRENT_DATE,
  fired_at DATE,
  CONSTRAINT employee_dates_chk CHECK (fired_at IS NULL OR fired_at >= hired_at)
);

CREATE TABLE customer (
  customer_id BIGSERIAL PRIMARY KEY,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(20) NOT NULL,
  email VARCHAR(254),
  birth_date DATE,
  driver_license_no VARCHAR(32) NOT NULL UNIQUE,
  driver_license_issued DATE,
  driver_license_expires DATE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT customer_email_chk CHECK (email IS NULL OR POSITION('@' IN email) > 1),
  CONSTRAINT customer_dl_dates_chk CHECK (
    driver_license_issued IS NULL
    OR driver_license_expires IS NULL
    OR driver_license_expires >= driver_license_issued
  )
);

CREATE TABLE car_model (
  model_id BIGSERIAL PRIMARY KEY,
  make VARCHAR(40) NOT NULL,
  model VARCHAR(60) NOT NULL,
  production_year SMALLINT NOT NULL,
  category_name VARCHAR(50) NOT NULL REFERENCES car_category(category_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  fuel_name VARCHAR(30) NOT NULL REFERENCES fuel_type(fuel_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  transmission_name VARCHAR(20) NOT NULL REFERENCES transmission_type(transmission_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  seats SMALLINT NOT NULL,
  UNIQUE (make, model, production_year, category_name, fuel_name, transmission_name),
  CONSTRAINT car_model_year_chk CHECK (production_year BETWEEN 1980 AND 2100),
  CONSTRAINT car_model_seats_chk CHECK (seats BETWEEN 1 AND 15)
);

CREATE TABLE car (
  car_id BIGSERIAL PRIMARY KEY,
  model_id BIGINT NOT NULL REFERENCES car_model(model_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  current_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  plate_no VARCHAR(15) NOT NULL UNIQUE,
  vin CHAR(17) NOT NULL UNIQUE,
  color VARCHAR(30),
  odometer_km INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT car_vin_chk CHECK (LENGTH(vin) = 17),
  CONSTRAINT car_odometer_chk CHECK (odometer_km >= 0)
);

CREATE TABLE rental (
  rental_id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  car_id BIGINT NOT NULL REFERENCES car(car_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  pickup_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  dropoff_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  opened_by_employee_id BIGINT NOT NULL REFERENCES employee(employee_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  status_name VARCHAR(30) NOT NULL REFERENCES rental_status(status_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  planned_start TIMESTAMP NOT NULL,
  planned_end TIMESTAMP NOT NULL,
  actual_start TIMESTAMP,
  actual_end TIMESTAMP,
  daily_rate NUMERIC(10,2) NOT NULL,
  deposit_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  notes VARCHAR(500),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT rental_planned_period_chk CHECK (planned_end > planned_start),
  CONSTRAINT rental_actual_period_chk CHECK (
    actual_start IS NULL
    OR actual_end IS NULL
    OR actual_end >= actual_start
  ),
  CONSTRAINT rental_rate_chk CHECK (daily_rate > 0),
  CONSTRAINT rental_deposit_chk CHECK (deposit_amount >= 0)
);

CREATE TABLE payment (
  payment_id BIGSERIAL PRIMARY KEY,
  rental_id BIGINT NOT NULL REFERENCES rental(rental_id) ON UPDATE CASCADE ON DELETE CASCADE,
  method_name VARCHAR(30) NOT NULL REFERENCES payment_method(method_name) ON UPDATE CASCADE ON DELETE RESTRICT,
  paid_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  amount NUMERIC(12,2) NOT NULL,
  is_refund BOOLEAN NOT NULL DEFAULT FALSE,
  CONSTRAINT payment_amount_chk CHECK (amount > 0)
);

CREATE TABLE maintenance (
  maintenance_id BIGSERIAL PRIMARY KEY,
  car_id BIGINT NOT NULL REFERENCES car(car_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  performed_by_employee_id BIGINT REFERENCES employee(employee_id) ON UPDATE CASCADE ON DELETE SET NULL,
  service_start TIMESTAMP NOT NULL,
  service_end TIMESTAMP NOT NULL,
  odometer_km INTEGER,
  description VARCHAR(400) NOT NULL,
  cost_amount NUMERIC(12,2),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT maintenance_period_chk CHECK (service_end > service_start),
  CONSTRAINT maintenance_odometer_chk CHECK (odometer_km IS NULL OR odometer_km >= 0),
  CONSTRAINT maintenance_cost_chk CHECK (cost_amount IS NULL OR cost_amount >= 0)
);

-- =========================
-- Триггеры
-- =========================

CREATE OR REPLACE FUNCTION trg_rental_period_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status_name <> 'отменен' THEN
    IF EXISTS (
      SELECT 1
      FROM rental r
      WHERE r.car_id = NEW.car_id
        AND r.rental_id <> COALESCE(NEW.rental_id, -1)
        AND r.status_name <> 'отменен'
        AND NEW.planned_start < r.planned_end
        AND NEW.planned_end > r.planned_start
    ) THEN
      RAISE EXCEPTION 'Автомобиль уже занят в указанный период';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM maintenance m
      WHERE m.car_id = NEW.car_id
        AND NEW.planned_start < m.service_end
        AND NEW.planned_end > m.service_start
    ) THEN
      RAISE EXCEPTION 'Автомобиль находится на обслуживании в указанный период';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_period_biu
BEFORE INSERT OR UPDATE OF car_id, planned_start, planned_end, status_name
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_rental_period_check();

CREATE OR REPLACE FUNCTION trg_maintenance_period_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM maintenance m
    WHERE m.car_id = NEW.car_id
      AND m.maintenance_id <> COALESCE(NEW.maintenance_id, -1)
      AND NEW.service_start < m.service_end
      AND NEW.service_end > m.service_start
  ) THEN
    RAISE EXCEPTION 'Для автомобиля уже есть обслуживание в указанный период';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM rental r
    WHERE r.car_id = NEW.car_id
      AND r.status_name <> 'отменен'
      AND NEW.service_start < r.planned_end
      AND NEW.service_end > r.planned_start
  ) THEN
    RAISE EXCEPTION 'Период обслуживания пересекается с арендой автомобиля';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER maintenance_period_biu
BEFORE INSERT OR UPDATE OF car_id, service_start, service_end
ON maintenance
FOR EACH ROW
EXECUTE FUNCTION trg_maintenance_period_check();

CREATE OR REPLACE FUNCTION trg_car_must_be_active()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  car_is_active BOOLEAN;
BEGIN
  IF NEW.status_name NOT IN ('новый', 'активный') THEN
    RETURN NEW;
  END IF;

  SELECT active INTO car_is_active
  FROM car
  WHERE car_id = NEW.car_id;

  IF car_is_active IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Неактивный автомобиль нельзя сдать в аренду';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_car_active_biu
BEFORE INSERT OR UPDATE OF car_id, status_name
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_car_must_be_active();

CREATE OR REPLACE FUNCTION trg_customer_license_valid()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  license_issued DATE;
  license_expires DATE;
BEGIN
  SELECT driver_license_issued, driver_license_expires
    INTO license_issued, license_expires
  FROM customer
  WHERE customer_id = NEW.customer_id;

  IF license_issued IS NOT NULL AND license_issued > CAST(NEW.planned_start AS DATE) THEN
    RAISE EXCEPTION 'Водительское удостоверение клиента еще не действует на дату начала аренды';
  END IF;

  IF license_expires IS NOT NULL AND license_expires < CAST(NEW.planned_end AS DATE) THEN
    RAISE EXCEPTION 'Водительское удостоверение клиента истекает до окончания аренды';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_customer_license_biu
BEFORE INSERT OR UPDATE OF customer_id, planned_start, planned_end
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_customer_license_valid();

CREATE OR REPLACE FUNCTION trg_rental_opened_by_agent_or_manager()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  employee_role_name VARCHAR(50);
BEGIN
  SELECT role_name INTO employee_role_name
  FROM employee
  WHERE employee_id = NEW.opened_by_employee_id;

  IF employee_role_name NOT IN ('агент проката', 'менеджер') THEN
    RAISE EXCEPTION 'Договор аренды может открыть только агент проката или менеджер';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_opened_by_role_biu
BEFORE INSERT OR UPDATE OF opened_by_employee_id
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_rental_opened_by_agent_or_manager();

CREATE OR REPLACE FUNCTION trg_maintenance_performed_by_mechanic()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  employee_role_name VARCHAR(50);
BEGIN
  IF NEW.performed_by_employee_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT role_name INTO employee_role_name
  FROM employee
  WHERE employee_id = NEW.performed_by_employee_id;

  IF employee_role_name <> 'механик' THEN
    RAISE EXCEPTION 'Обслуживание автомобиля должен выполнять механик';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER maintenance_performed_by_role_biu
BEFORE INSERT OR UPDATE OF performed_by_employee_id
ON maintenance
FOR EACH ROW
EXECUTE FUNCTION trg_maintenance_performed_by_mechanic();

CREATE OR REPLACE FUNCTION trg_payment_not_for_canceled_rental()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM rental r
    WHERE r.rental_id = NEW.rental_id
      AND r.status_name = 'отменен'
  ) THEN
    RAISE EXCEPTION 'Нельзя внести платеж по отмененному договору';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER payment_not_for_canceled_rental_biu
BEFORE INSERT OR UPDATE OF rental_id
ON payment
FOR EACH ROW
EXECUTE FUNCTION trg_payment_not_for_canceled_rental();

-- =========================
-- Представления
-- =========================

CREATE VIEW v_cars AS
SELECT
  c.car_id,
  c.plate_no,
  c.vin,
  c.color,
  c.odometer_km,
  c.active,
  b.branch_name AS current_branch_name,
  b.city AS current_city,
  m.make,
  m.model,
  m.production_year,
  m.category_name,
  m.fuel_name,
  m.transmission_name,
  m.seats
FROM car c
JOIN branch b ON b.branch_id = c.current_branch_id
JOIN car_model m ON m.model_id = c.model_id;

CREATE VIEW v_active_rentals AS
SELECT
  r.rental_id,
  r.status_name,
  r.planned_start,
  r.planned_end,
  r.actual_start,
  r.actual_end,
  r.daily_rate,
  r.deposit_amount,
  c.customer_id,
  c.full_name AS customer_name,
  car.car_id,
  car.plate_no,
  pickup.branch_name AS pickup_branch,
  dropoff.branch_name AS dropoff_branch,
  e.employee_id,
  e.full_name AS opened_by
FROM rental r
JOIN customer c ON c.customer_id = r.customer_id
JOIN car ON car.car_id = r.car_id
JOIN branch pickup ON pickup.branch_id = r.pickup_branch_id
JOIN branch dropoff ON dropoff.branch_id = r.dropoff_branch_id
JOIN employee e ON e.employee_id = r.opened_by_employee_id
WHERE r.status_name IN ('новый', 'активный');

CREATE VIEW v_rental_payment_net AS
SELECT
  p.rental_id,
  SUM(CASE WHEN p.is_refund THEN -p.amount ELSE p.amount END) AS net_amount
FROM payment p
GROUP BY p.rental_id;

CREATE VIEW v_rentals_pricing AS
SELECT
  r.rental_id,
  r.customer_id,
  r.car_id,
  r.status_name,
  r.planned_start,
  r.planned_end,
  r.daily_rate,
  r.deposit_amount,
  GREATEST(1, CAST(r.planned_end AS DATE) - CAST(r.planned_start AS DATE)) AS planned_days,
  GREATEST(1, CAST(r.planned_end AS DATE) - CAST(r.planned_start AS DATE)) * r.daily_rate AS planned_rent_amount,
  COALESCE(pn.net_amount, 0) AS paid_net_amount
FROM rental r
LEFT JOIN v_rental_payment_net pn ON pn.rental_id = r.rental_id;

CREATE VIEW v_overdue_rentals AS
SELECT *
FROM v_active_rentals
WHERE planned_end < CURRENT_TIMESTAMP;

CREATE VIEW v_cars_in_maintenance AS
SELECT
  m.maintenance_id,
  m.car_id,
  c.plate_no,
  m.service_start,
  m.service_end,
  m.description,
  m.cost_amount
FROM maintenance m
JOIN car c ON c.car_id = m.car_id
WHERE CURRENT_TIMESTAMP >= m.service_start
  AND CURRENT_TIMESTAMP < m.service_end;

CREATE VIEW v_available_cars_now AS
SELECT vc.*
FROM v_cars vc
WHERE vc.active = TRUE
  AND NOT EXISTS (
    SELECT 1
    FROM maintenance m
    WHERE m.car_id = vc.car_id
      AND CURRENT_TIMESTAMP >= m.service_start
      AND CURRENT_TIMESTAMP < m.service_end
  )
  AND NOT EXISTS (
    SELECT 1
    FROM rental r
    WHERE r.car_id = vc.car_id
      AND r.status_name IN ('новый', 'активный')
      AND CURRENT_TIMESTAMP >= r.planned_start
      AND CURRENT_TIMESTAMP < r.planned_end
  );

CREATE VIEW v_revenue_by_month AS
SELECT
  EXTRACT(YEAR FROM p.paid_at) AS pay_year,
  EXTRACT(MONTH FROM p.paid_at) AS pay_month,
  SUM(CASE WHEN p.is_refund THEN -p.amount ELSE p.amount END) AS revenue_net
FROM payment p
GROUP BY EXTRACT(YEAR FROM p.paid_at), EXTRACT(MONTH FROM p.paid_at);

CREATE VIEW v_customer_rental_history AS
SELECT
  c.customer_id,
  c.full_name,
  r.rental_id,
  r.status_name,
  r.planned_start,
  r.planned_end,
  r.actual_start,
  r.actual_end,
  car.plate_no,
  r.created_at
FROM customer c
JOIN rental r ON r.customer_id = c.customer_id
JOIN car ON car.car_id = r.car_id;

CREATE VIEW v_car_utilization AS
SELECT
  r.car_id,
  car.plate_no,
  SUM(GREATEST(1, CAST(r.planned_end AS DATE) - CAST(r.planned_start AS DATE))) AS planned_days_total
FROM rental r
JOIN car ON car.car_id = r.car_id
WHERE r.status_name <> 'отменен'
GROUP BY r.car_id, car.plate_no;

-- =========================
-- Индексы
-- =========================

CREATE INDEX idx_employee_branch_id ON employee(branch_id);
CREATE INDEX idx_employee_role_name ON employee(role_name);
CREATE INDEX idx_car_model_category_name ON car_model(category_name);
CREATE INDEX idx_car_model_fuel_name ON car_model(fuel_name);
CREATE INDEX idx_car_model_transmission_name ON car_model(transmission_name);
CREATE INDEX idx_car_model_id ON car(model_id);
CREATE INDEX idx_car_current_branch_id ON car(current_branch_id);
CREATE INDEX idx_rental_customer_id ON rental(customer_id);
CREATE INDEX idx_rental_car_id ON rental(car_id);
CREATE INDEX idx_rental_pickup_branch_id ON rental(pickup_branch_id);
CREATE INDEX idx_rental_dropoff_branch_id ON rental(dropoff_branch_id);
CREATE INDEX idx_rental_opened_by_employee_id ON rental(opened_by_employee_id);
CREATE INDEX idx_rental_status_name ON rental(status_name);
CREATE INDEX idx_payment_rental_id ON payment(rental_id);
CREATE INDEX idx_payment_method_name ON payment(method_name);
CREATE INDEX idx_payment_paid_at ON payment(paid_at);
CREATE INDEX idx_maintenance_car_id ON maintenance(car_id);
CREATE INDEX idx_maintenance_performed_by_employee_id ON maintenance(performed_by_employee_id);
CREATE INDEX idx_rental_car_period ON rental(car_id, planned_start, planned_end);
CREATE INDEX idx_maintenance_car_period ON maintenance(car_id, service_start, service_end);

-- =========================
-- Первоначальное заполнение справочников
-- =========================

INSERT INTO car_category(category_name) VALUES
  ('эконом'),
  ('стандарт'),
  ('кроссовер'),
  ('бизнес');

INSERT INTO fuel_type(fuel_name) VALUES
  ('бензин'),
  ('дизель'),
  ('электро'),
  ('гибрид');

INSERT INTO transmission_type(transmission_name) VALUES
  ('автоматическая'),
  ('механическая');

INSERT INTO payment_method(method_name) VALUES
  ('наличные'),
  ('банковская карта'),
  ('безналичный перевод');

INSERT INTO employee_role(role_name) VALUES
  ('менеджер'),
  ('агент проката'),
  ('механик'),
  ('бухгалтер');

INSERT INTO rental_status(status_name) VALUES
  ('новый'),
  ('активный'),
  ('закрыт'),
  ('отменен');

-- =========================
-- Роли и права доступа
-- =========================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cr_manager') THEN
    CREATE ROLE cr_manager;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cr_agent') THEN
    CREATE ROLE cr_agent;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cr_accountant') THEN
    CREATE ROLE cr_accountant;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cr_mechanic') THEN
    CREATE ROLE cr_mechanic;
  END IF;
END$$;

GRANT USAGE ON SCHEMA car_rental TO cr_manager, cr_agent, cr_accountant, cr_mechanic;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA car_rental TO cr_manager;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA car_rental TO cr_manager;

GRANT SELECT ON
  branch, car, car_model, car_category, fuel_type, transmission_type, rental_status
TO cr_agent;
GRANT SELECT, INSERT, UPDATE ON customer, rental TO cr_agent;
GRANT SELECT ON
  v_cars, v_active_rentals, v_overdue_rentals, v_available_cars_now,
  v_customer_rental_history
TO cr_agent;
GRANT USAGE, SELECT ON SEQUENCE customer_customer_id_seq, rental_rental_id_seq TO cr_agent;

GRANT SELECT ON rental, customer, car, branch, payment_method, rental_status TO cr_accountant;
GRANT SELECT, INSERT, UPDATE ON payment TO cr_accountant;
GRANT SELECT ON v_rental_payment_net, v_rentals_pricing, v_revenue_by_month TO cr_accountant;
GRANT USAGE, SELECT ON SEQUENCE payment_payment_id_seq TO cr_accountant;

GRANT SELECT ON car, car_model, branch TO cr_mechanic;
GRANT SELECT, INSERT, UPDATE ON maintenance TO cr_mechanic;
GRANT SELECT ON v_cars_in_maintenance TO cr_mechanic;
GRANT USAGE, SELECT ON SEQUENCE maintenance_maintenance_id_seq TO cr_mechanic;
