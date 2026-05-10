-- Smoke checks for car_rental.sql (PostgreSQL)
-- Run after car_rental.sql. The script inserts minimal non-reference data
-- and verifies the most important constraints/triggers.

SET search_path TO car_rental;

INSERT INTO branch(branch_name, city, address, phone)
VALUES ('Central branch', 'Moscow', 'Tverskaya st., 1', '+7 495 000-00-00');

INSERT INTO employee(branch_id, role_code, full_name, phone, hired_at)
VALUES
  (1, 'MGR ', 'Manager Test', '+7 900 100-00-01', DATE '2024-01-10'),
  (1, 'AGNT', 'Agent Test', '+7 900 100-00-02', DATE '2024-01-10'),
  (1, 'MECH', 'Mechanic Test', '+7 900 100-00-03', DATE '2024-01-10'),
  (1, 'ACCT', 'Accountant Test', '+7 900 100-00-04', DATE '2024-01-10');

INSERT INTO customer(
  full_name,
  phone,
  email,
  birth_date,
  driver_license_no,
  driver_license_issued,
  driver_license_expires
)
VALUES
  ('Customer Test', '+7 900 200-00-01', 'customer@example.com', DATE '1995-03-01',
   'DL-TEST-001', DATE '2020-01-01', DATE '2030-01-01'),
  ('Expired License Test', '+7 900 200-00-02', 'expired@example.com', DATE '1990-05-12',
   'DL-TEST-002', DATE '2015-01-01', DATE '2025-01-01');

INSERT INTO car_model(make, model, year, category_code, fuel_code, transmission_code, seats)
VALUES ('Toyota', 'Corolla', 2022, 'STND', 'G', 'A', 5);

INSERT INTO car(model_id, current_branch_id, plate_no, vin, color, odometer_km, active)
VALUES
  (1, 1, 'A001AA777', 'JTDBR32E720000001', 'White', 12000, TRUE),
  (1, 1, 'A002AA777', 'JTDBR32E720000002', 'Black', 8000, FALSE);

-- Valid rental.
INSERT INTO rental(
  customer_id,
  car_id,
  pickup_branch_id,
  dropoff_branch_id,
  opened_by_employee_id,
  status_code,
  planned_period,
  daily_rate,
  deposit_amount
)
VALUES (
  1, 1, 1, 1, 2, 'NEW',
  tstzrange('2026-06-01 10:00+03', '2026-06-05 10:00+03', '[)'),
  3500.00,
  10000.00
);

-- Valid payment and maintenance outside the rental period.
INSERT INTO payment(rental_id, method_code, paid_at, amount, is_refund)
VALUES (1, 'CARD', '2026-06-01 09:30+03', 14000.00, FALSE);

INSERT INTO maintenance(car_id, performed_by_employee_id, service_period, odometer_km, description, cost_amount)
VALUES (1, 3, tstzrange('2026-06-10 09:00+03', '2026-06-11 18:00+03', '[)'), 12100, 'Planned service', 4500.00);

-- Expected failure: double booking the same car.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_code, planned_period, daily_rate, deposit_amount)
    VALUES (1, 1, 1, 1, 2, 'NEW',
            tstzrange('2026-06-03 10:00+03', '2026-06-07 10:00+03', '[)'), 3500.00, 10000.00);
    RAISE EXCEPTION 'Expected double-booking check to fail';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK: overlapping rental was rejected';
  END;
END$$;

-- Expected failure: inactive car cannot be rented.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_code, planned_period, daily_rate, deposit_amount)
    VALUES (1, 2, 1, 1, 2, 'NEW',
            tstzrange('2026-07-01 10:00+03', '2026-07-05 10:00+03', '[)'), 3500.00, 10000.00);
    RAISE EXCEPTION 'Expected inactive-car check to fail';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'OK: inactive car was rejected';
  END;
END$$;

-- Expected failure: expired license for the planned rental period.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_code, planned_period, daily_rate, deposit_amount)
    VALUES (2, 1, 1, 1, 2, 'NEW',
            tstzrange('2026-08-01 10:00+03', '2026-08-05 10:00+03', '[)'), 3500.00, 10000.00);
    RAISE EXCEPTION 'Expected driver-license check to fail';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'OK: expired driver license was rejected';
  END;
END$$;

SELECT * FROM v_available_cars_now;
SELECT * FROM v_revenue_by_month;
