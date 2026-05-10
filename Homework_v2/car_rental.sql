-- Car rental company database (PostgreSQL)
-- Generated for HSE DB course homework (topic: car rental firm)

-- Recreate schema
DROP SCHEMA IF EXISTS car_rental CASCADE;
CREATE SCHEMA car_rental;
SET search_path TO car_rental;

-- Extensions (used for exclusion constraints with plain types + ranges)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =========================
-- Reference (lookup) tables
-- =========================

CREATE TABLE car_category (
  category_code CHAR(4) PRIMARY KEY,
  category_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE fuel_type (
  fuel_code CHAR(2) PRIMARY KEY,
  fuel_name VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE transmission_type (
  transmission_code CHAR(1) PRIMARY KEY,
  transmission_name VARCHAR(20) NOT NULL UNIQUE
);

CREATE TABLE payment_method (
  method_code CHAR(4) PRIMARY KEY,
  method_name VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE employee_role (
  role_code CHAR(4) PRIMARY KEY,
  role_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE rental_status (
  status_code CHAR(3) PRIMARY KEY,
  status_name VARCHAR(30) NOT NULL UNIQUE
);

-- ============
-- Core tables
-- ============

CREATE TABLE branch (
  branch_id BIGSERIAL PRIMARY KEY,
  branch_name VARCHAR(100) NOT NULL UNIQUE,
  city VARCHAR(60) NOT NULL,
  address VARCHAR(200) NOT NULL,
  phone VARCHAR(20) NULL
);

CREATE TABLE employee (
  employee_id BIGSERIAL PRIMARY KEY,
  branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  role_code CHAR(4) NOT NULL REFERENCES employee_role(role_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(20) NULL,
  hired_at DATE NOT NULL DEFAULT CURRENT_DATE,
  fired_at DATE NULL,
  CONSTRAINT employee_dates_chk CHECK (fired_at IS NULL OR fired_at >= hired_at)
);

CREATE TABLE customer (
  customer_id BIGSERIAL PRIMARY KEY,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(20) NOT NULL,
  email VARCHAR(254) NULL,
  birth_date DATE NULL,
  driver_license_no VARCHAR(32) NOT NULL UNIQUE,
  driver_license_issued DATE NULL,
  driver_license_expires DATE NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT customer_email_chk CHECK (email IS NULL OR position('@' in email) > 1),
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
  year SMALLINT NOT NULL,
  category_code CHAR(4) NOT NULL REFERENCES car_category(category_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  fuel_code CHAR(2) NOT NULL REFERENCES fuel_type(fuel_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  transmission_code CHAR(1) NOT NULL REFERENCES transmission_type(transmission_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  seats SMALLINT NOT NULL,
  UNIQUE (make, model, year, category_code, fuel_code, transmission_code),
  CONSTRAINT car_model_year_chk CHECK (year BETWEEN 1980 AND 2100),
  CONSTRAINT car_model_seats_chk CHECK (seats BETWEEN 1 AND 15)
);

CREATE TABLE car (
  car_id BIGSERIAL PRIMARY KEY,
  model_id BIGINT NOT NULL REFERENCES car_model(model_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  current_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  plate_no VARCHAR(15) NOT NULL UNIQUE,
  vin CHAR(17) NOT NULL UNIQUE,
  color VARCHAR(30) NULL,
  odometer_km INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT car_vin_chk CHECK (length(vin) = 17),
  CONSTRAINT car_odometer_chk CHECK (odometer_km >= 0)
);

CREATE TABLE rental (
  rental_id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  car_id BIGINT NOT NULL REFERENCES car(car_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  pickup_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  dropoff_branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  opened_by_employee_id BIGINT NOT NULL REFERENCES employee(employee_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  status_code CHAR(3) NOT NULL REFERENCES rental_status(status_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  planned_period TSTZRANGE NOT NULL,
  actual_period TSTZRANGE NULL,
  daily_rate NUMERIC(10,2) NOT NULL,
  deposit_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  notes VARCHAR(500) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT rental_rate_chk CHECK (daily_rate > 0),
  CONSTRAINT rental_deposit_chk CHECK (deposit_amount >= 0),
  CONSTRAINT rental_planned_period_chk CHECK (lower(planned_period) < upper(planned_period)),
  CONSTRAINT rental_actual_period_chk CHECK (actual_period IS NULL OR lower(actual_period) < upper(actual_period))
);

-- Prevent double-booking: rentals of same car may not overlap by planned period
-- (canceled rentals do not participate in constraint)
ALTER TABLE rental
  ADD CONSTRAINT rental_no_overlap_per_car
  EXCLUDE USING gist (
    car_id WITH =,
    planned_period WITH &&
  )
  WHERE (status_code <> 'CNL');

CREATE TABLE payment (
  payment_id BIGSERIAL PRIMARY KEY,
  rental_id BIGINT NOT NULL REFERENCES rental(rental_id) ON UPDATE CASCADE ON DELETE CASCADE,
  method_code CHAR(4) NOT NULL REFERENCES payment_method(method_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  amount NUMERIC(12,2) NOT NULL,
  is_refund BOOLEAN NOT NULL DEFAULT FALSE,
  CONSTRAINT payment_amount_chk CHECK (amount > 0)
);

CREATE TABLE maintenance (
  maintenance_id BIGSERIAL PRIMARY KEY,
  car_id BIGINT NOT NULL REFERENCES car(car_id) ON UPDATE CASCADE ON DELETE RESTRICT,
  performed_by_employee_id BIGINT NULL REFERENCES employee(employee_id) ON UPDATE CASCADE ON DELETE SET NULL,
  service_period TSTZRANGE NOT NULL,
  odometer_km INTEGER NULL,
  description VARCHAR(400) NOT NULL,
  cost_amount NUMERIC(12,2) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT maintenance_period_chk CHECK (lower(service_period) < upper(service_period)),
  CONSTRAINT maintenance_odometer_chk CHECK (odometer_km IS NULL OR odometer_km >= 0),
  CONSTRAINT maintenance_cost_chk CHECK (cost_amount IS NULL OR cost_amount >= 0)
);

-- Prevent overlapping maintenance periods for the same car
ALTER TABLE maintenance
  ADD CONSTRAINT maintenance_no_overlap_per_car
  EXCLUDE USING gist (
    car_id WITH =,
    service_period WITH &&
  );

-- ==========
-- Triggers
-- ==========

CREATE OR REPLACE FUNCTION trg_rental_period_not_in_maintenance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Serialize period checks for one car to avoid concurrent cross-table inserts.
  PERFORM pg_advisory_xact_lock(NEW.car_id);

  -- Canceled rentals do not block maintenance periods.
  IF NEW.status_code <> 'CNL' THEN
    IF EXISTS (
      SELECT 1
      FROM maintenance m
      WHERE m.car_id = NEW.car_id
        AND m.service_period && NEW.planned_period
    ) THEN
      RAISE EXCEPTION 'Car % is in maintenance during planned rental period', NEW.car_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_not_in_maintenance_biu
BEFORE INSERT OR UPDATE OF car_id, planned_period, status_code
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_rental_period_not_in_maintenance();

CREATE OR REPLACE FUNCTION trg_maintenance_not_overlap_rentals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Serialize period checks for one car to avoid concurrent cross-table inserts.
  PERFORM pg_advisory_xact_lock(NEW.car_id);

  IF EXISTS (
    SELECT 1
    FROM rental r
    WHERE r.car_id = NEW.car_id
      AND r.status_code <> 'CNL'
      AND r.planned_period && NEW.service_period
  ) THEN
    RAISE EXCEPTION 'Maintenance period overlaps existing rental plan for car %', NEW.car_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER maintenance_not_overlap_rentals_biu
BEFORE INSERT OR UPDATE OF car_id, service_period
ON maintenance
FOR EACH ROW
EXECUTE FUNCTION trg_maintenance_not_overlap_rentals();

CREATE OR REPLACE FUNCTION trg_rental_set_actual_period()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- If rental is closed and actual_period is missing, set it to planned_period
  IF NEW.status_code = 'CLS' AND NEW.actual_period IS NULL THEN
    NEW.actual_period := NEW.planned_period;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_set_actual_period_biu
BEFORE INSERT OR UPDATE OF status_code, actual_period, planned_period
ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_rental_set_actual_period();

CREATE OR REPLACE FUNCTION trg_car_must_be_active()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  car_is_active BOOLEAN;
BEGIN
  IF NEW.status_code NOT IN ('NEW', 'ACT') THEN
    RETURN NEW;
  END IF;

  SELECT active INTO car_is_active FROM car WHERE car_id = NEW.car_id;
  IF car_is_active IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Car % is not active and cannot be rented', NEW.car_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_car_active_biu
BEFORE INSERT OR UPDATE OF car_id, status_code ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_car_must_be_active();

CREATE OR REPLACE FUNCTION trg_customer_license_valid_for_rental()
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

  IF license_issued IS NOT NULL AND license_issued > lower(NEW.planned_period)::date THEN
    RAISE EXCEPTION 'Customer % driver license is not valid at rental start', NEW.customer_id;
  END IF;

  IF license_expires IS NOT NULL AND license_expires < upper(NEW.planned_period)::date THEN
    RAISE EXCEPTION 'Customer % driver license expires before rental end', NEW.customer_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_customer_license_biu
BEFORE INSERT OR UPDATE OF customer_id, planned_period ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_customer_license_valid_for_rental();

CREATE OR REPLACE FUNCTION trg_rental_opened_by_agent_or_manager()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  employee_role_code CHAR(4);
BEGIN
  SELECT role_code INTO employee_role_code
  FROM employee
  WHERE employee_id = NEW.opened_by_employee_id;

  IF employee_role_code NOT IN ('AGNT', 'MGR ') THEN
    RAISE EXCEPTION 'Employee % cannot open rental contracts', NEW.opened_by_employee_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER rental_opened_by_role_biu
BEFORE INSERT OR UPDATE OF opened_by_employee_id ON rental
FOR EACH ROW
EXECUTE FUNCTION trg_rental_opened_by_agent_or_manager();

CREATE OR REPLACE FUNCTION trg_maintenance_performed_by_mechanic()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  employee_role_code CHAR(4);
BEGIN
  IF NEW.performed_by_employee_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT role_code INTO employee_role_code
  FROM employee
  WHERE employee_id = NEW.performed_by_employee_id;

  IF employee_role_code <> 'MECH' THEN
    RAISE EXCEPTION 'Employee % cannot be assigned as mechanic', NEW.performed_by_employee_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER maintenance_performed_by_role_biu
BEFORE INSERT OR UPDATE OF performed_by_employee_id ON maintenance
FOR EACH ROW
EXECUTE FUNCTION trg_maintenance_performed_by_mechanic();

-- ======================
-- Views (ready queries)
-- ======================

-- 1) Cars with model details
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
  m.year,
  cc.category_name,
  ft.fuel_name,
  tt.transmission_name,
  m.seats
FROM car c
JOIN branch b ON b.branch_id = c.current_branch_id
JOIN car_model m ON m.model_id = c.model_id
JOIN car_category cc ON cc.category_code = m.category_code
JOIN fuel_type ft ON ft.fuel_code = m.fuel_code
JOIN transmission_type tt ON tt.transmission_code = m.transmission_code;

-- 2) Active rentals
CREATE VIEW v_active_rentals AS
SELECT
  r.rental_id,
  r.status_code,
  rs.status_name,
  r.planned_period,
  r.actual_period,
  r.daily_rate,
  r.deposit_amount,
  r.created_at,
  c.customer_id,
  c.full_name AS customer_name,
  car.car_id,
  car.plate_no,
  pb.branch_name AS pickup_branch,
  db.branch_name AS dropoff_branch,
  e.employee_id,
  e.full_name AS opened_by
FROM rental r
JOIN rental_status rs ON rs.status_code = r.status_code
JOIN customer c ON c.customer_id = r.customer_id
JOIN car ON car.car_id = r.car_id
JOIN branch pb ON pb.branch_id = r.pickup_branch_id
JOIN branch db ON db.branch_id = r.dropoff_branch_id
JOIN employee e ON e.employee_id = r.opened_by_employee_id
WHERE r.status_code IN ('NEW', 'ACT');

-- 3) Payments by rental (net)
CREATE VIEW v_rental_payment_net AS
SELECT
  p.rental_id,
  SUM(CASE WHEN p.is_refund THEN -p.amount ELSE p.amount END) AS net_amount
FROM payment p
GROUP BY p.rental_id;

-- 4) Rentals with computed planned days
CREATE VIEW v_rentals_pricing AS
SELECT
  r.rental_id,
  r.customer_id,
  r.car_id,
  r.status_code,
  r.planned_period,
  r.daily_rate,
  r.deposit_amount,
  GREATEST(1, CEIL(EXTRACT(EPOCH FROM (upper(r.planned_period) - lower(r.planned_period))) / 86400.0))::INT) AS planned_days,
  (GREATEST(1, CEIL(EXTRACT(EPOCH FROM (upper(r.planned_period) - lower(r.planned_period))) / 86400.0))::INT) * r.daily_rate) AS planned_rent_amount,
  COALESCE(pn.net_amount, 0) AS paid_net_amount
FROM rental r
LEFT JOIN v_rental_payment_net pn ON pn.rental_id = r.rental_id;

-- 5) Overdue rentals (planned end passed, still active)
CREATE VIEW v_overdue_rentals AS
SELECT
  ar.*
FROM v_active_rentals ar
WHERE upper(ar.planned_period) < NOW();

-- 6) Cars currently in maintenance
CREATE VIEW v_cars_in_maintenance AS
SELECT
  m.maintenance_id,
  m.car_id,
  c.plate_no,
  m.service_period,
  m.description,
  m.cost_amount
FROM maintenance m
JOIN car c ON c.car_id = m.car_id
WHERE m.service_period @> NOW();

-- 7) Available cars at this moment (active, not in maintenance, not rented)
CREATE VIEW v_available_cars_now AS
SELECT
  vc.*
FROM v_cars vc
WHERE vc.active = TRUE
  AND NOT EXISTS (
    SELECT 1
    FROM maintenance m
    WHERE m.car_id = vc.car_id
      AND m.service_period @> NOW()
  )
  AND NOT EXISTS (
    SELECT 1
    FROM rental r
    WHERE r.car_id = vc.car_id
      AND r.status_code IN ('NEW', 'ACT')
      AND r.planned_period @> NOW()
  );

-- 8) Revenue by month (based on payments)
CREATE VIEW v_revenue_by_month AS
SELECT
  date_trunc('month', p.paid_at) AS month,
  SUM(CASE WHEN p.is_refund THEN -p.amount ELSE p.amount END) AS revenue_net
FROM payment p
GROUP BY date_trunc('month', p.paid_at)
ORDER BY month;

-- 9) Customer rental history
CREATE VIEW v_customer_rental_history AS
SELECT
  c.customer_id,
  c.full_name,
  r.rental_id,
  r.status_code,
  rs.status_name,
  r.planned_period,
  r.actual_period,
  car.plate_no,
  r.created_at
FROM customer c
JOIN rental r ON r.customer_id = c.customer_id
JOIN rental_status rs ON rs.status_code = r.status_code
JOIN car ON car.car_id = r.car_id;

-- 10) Cars utilization (total planned days per car)
CREATE VIEW v_car_utilization AS
SELECT
  r.car_id,
  car.plate_no,
  SUM(
    GREATEST(1, CEIL(EXTRACT(EPOCH FROM (upper(r.planned_period) - lower(r.planned_period))) / 86400.0))::INT)
  ) AS planned_days_total
FROM rental r
JOIN car ON car.car_id = r.car_id
WHERE r.status_code <> 'CNL'
GROUP BY r.car_id, car.plate_no;

-- ========
-- Indexes
-- ========

-- Foreign keys / frequent filters
CREATE INDEX idx_employee_branch_id ON employee(branch_id);
CREATE INDEX idx_employee_role_code ON employee(role_code);
CREATE INDEX idx_car_model_category_code ON car_model(category_code);
CREATE INDEX idx_car_model_fuel_code ON car_model(fuel_code);
CREATE INDEX idx_car_model_transmission_code ON car_model(transmission_code);
CREATE INDEX idx_car_model_id ON car(model_id);
CREATE INDEX idx_car_current_branch_id ON car(current_branch_id);
CREATE INDEX idx_rental_customer_id ON rental(customer_id);
CREATE INDEX idx_rental_car_id ON rental(car_id);
CREATE INDEX idx_rental_pickup_branch_id ON rental(pickup_branch_id);
CREATE INDEX idx_rental_dropoff_branch_id ON rental(dropoff_branch_id);
CREATE INDEX idx_rental_opened_by_employee_id ON rental(opened_by_employee_id);
CREATE INDEX idx_rental_status_code ON rental(status_code);
CREATE INDEX idx_payment_rental_id ON payment(rental_id);
CREATE INDEX idx_payment_method_code ON payment(method_code);
CREATE INDEX idx_payment_paid_at ON payment(paid_at);
CREATE INDEX idx_maintenance_car_id ON maintenance(car_id);
CREATE INDEX idx_maintenance_performed_by_employee_id ON maintenance(performed_by_employee_id);

-- Helpful composite index for analytics
CREATE INDEX idx_rental_car_status ON rental(car_id, status_code);

-- ==================
-- Minimal seed data
-- (only reference tables as required)
-- ==================

INSERT INTO car_category(category_code, category_name) VALUES
  ('ECON', 'Economy'),
  ('STND', 'Standard'),
  ('SUV ', 'SUV'),
  ('LUX ', 'Luxury');

INSERT INTO fuel_type(fuel_code, fuel_name) VALUES
  ('G', 'Gasoline'),
  ('D', 'Diesel'),
  ('E', 'Electric'),
  ('H', 'Hybrid');

INSERT INTO transmission_type(transmission_code, transmission_name) VALUES
  ('A', 'Automatic'),
  ('M', 'Manual');

INSERT INTO payment_method(method_code, method_name) VALUES
  ('CASH', 'Cash'),
  ('CARD', 'Card'),
  ('TRAN', 'Bank transfer');

INSERT INTO employee_role(role_code, role_name) VALUES
  ('MGR ', 'Manager'),
  ('AGNT', 'Rental agent'),
  ('MECH', 'Mechanic'),
  ('ACCT', 'Accountant');

INSERT INTO rental_status(status_code, status_name) VALUES
  ('NEW', 'New'),
  ('ACT', 'Active'),
  ('CLS', 'Closed'),
  ('CNL', 'Canceled');

-- ==================
-- Roles and grants
-- ==================

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

-- Manager: full access
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA car_rental TO cr_manager;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA car_rental TO cr_manager;

-- Agent: manage rentals, customers, cars read
GRANT SELECT ON branch, car, car_model, car_category, fuel_type, transmission_type, rental_status TO cr_agent;
GRANT SELECT, INSERT, UPDATE ON customer, rental TO cr_agent;
GRANT SELECT ON v_cars, v_active_rentals, v_overdue_rentals, v_available_cars_now, v_customer_rental_history TO cr_agent;
GRANT USAGE, SELECT ON SEQUENCE customer_customer_id_seq, rental_rental_id_seq TO cr_agent;

-- Accountant: payments and revenue
GRANT SELECT ON rental, customer, car, branch, payment_method, rental_status TO cr_accountant;
GRANT SELECT, INSERT, UPDATE ON payment TO cr_accountant;
GRANT SELECT ON v_rental_payment_net, v_rentals_pricing, v_revenue_by_month TO cr_accountant;
GRANT USAGE, SELECT ON SEQUENCE payment_payment_id_seq TO cr_accountant;

-- Mechanic: maintenance, car read
GRANT SELECT ON car, car_model, branch TO cr_mechanic;
GRANT SELECT, INSERT, UPDATE ON maintenance TO cr_mechanic;
GRANT SELECT ON v_cars_in_maintenance TO cr_mechanic;
GRANT USAGE, SELECT ON SEQUENCE maintenance_maintenance_id_seq TO cr_mechanic;
