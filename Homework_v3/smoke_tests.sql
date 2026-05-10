-- Проверка работоспособности основных ограничений.
-- Выполняется после car_rental.sql.

SET search_path TO car_rental;

INSERT INTO branch(branch_name, city, address, phone)
VALUES ('Центральный пункт проката', 'Москва', 'ул. Тверская, 1', '+7 495 000-00-00');

INSERT INTO employee(branch_id, role_name, full_name, phone, hired_at)
VALUES
  (1, 'менеджер', 'Иванов Сергей Петрович', '+7 900 100-00-01', DATE '2024-01-10'),
  (1, 'агент проката', 'Петрова Анна Игоревна', '+7 900 100-00-02', DATE '2024-01-10'),
  (1, 'механик', 'Сидоров Павел Андреевич', '+7 900 100-00-03', DATE '2024-01-10'),
  (1, 'бухгалтер', 'Кузнецова Мария Олеговна', '+7 900 100-00-04', DATE '2024-01-10');

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
  ('Смирнов Алексей Викторович', '+7 900 200-00-01', 'smirnov@example.ru', DATE '1995-03-01',
   '77АА000001', DATE '2020-01-01', DATE '2030-01-01'),
  ('Орлова Елена Сергеевна', '+7 900 200-00-02', 'orlova@example.ru', DATE '1990-05-12',
   '77АА000002', DATE '2015-01-01', DATE '2025-01-01');

INSERT INTO car_model(make, model, production_year, category_name, fuel_name, transmission_name, seats)
VALUES ('Toyota', 'Corolla', 2022, 'стандарт', 'бензин', 'автоматическая', 5);

INSERT INTO car(model_id, current_branch_id, plate_no, vin, color, odometer_km, active)
VALUES
  (1, 1, 'А001АА777', 'JTDBR32E720000001', 'белый', 12000, TRUE),
  (1, 1, 'А002АА777', 'JTDBR32E720000002', 'черный', 8000, FALSE),
  (1, 1, 'А003АА777', 'JTDBR32E720000003', 'серый', 6000, TRUE);

-- Корректный договор аренды.
INSERT INTO rental(
  customer_id,
  car_id,
  pickup_branch_id,
  dropoff_branch_id,
  opened_by_employee_id,
  status_name,
  planned_start,
  planned_end,
  daily_rate,
  deposit_amount
)
VALUES (
  1, 1, 1, 1, 2, 'новый',
  TIMESTAMP '2026-06-01 10:00:00',
  TIMESTAMP '2026-06-05 10:00:00',
  3500.00,
  10000.00
);

INSERT INTO payment(rental_id, method_name, paid_at, amount, is_refund)
VALUES (1, 'банковская карта', TIMESTAMP '2026-06-01 09:30:00', 14000.00, FALSE);

INSERT INTO maintenance(car_id, performed_by_employee_id, service_start, service_end, odometer_km, description, cost_amount)
VALUES (
  1, 3,
  TIMESTAMP '2026-06-10 09:00:00',
  TIMESTAMP '2026-06-11 18:00:00',
  12100,
  'Плановое техническое обслуживание',
  4500.00
);

-- Ожидаемая ошибка: повторная аренда того же автомобиля на пересекающийся период.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_name, planned_start, planned_end, daily_rate, deposit_amount)
    VALUES (1, 1, 1, 1, 2, 'новый',
            TIMESTAMP '2026-06-03 10:00:00', TIMESTAMP '2026-06-07 10:00:00',
            3500.00, 10000.00);
    RAISE EXCEPTION 'Проверка пересечения аренд не сработала';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'OK: пересекающаяся аренда отклонена';
  END;
END$$;

-- Ожидаемая ошибка: неактивный автомобиль нельзя сдавать в аренду.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_name, planned_start, planned_end, daily_rate, deposit_amount)
    VALUES (1, 2, 1, 1, 2, 'новый',
            TIMESTAMP '2026-07-01 10:00:00', TIMESTAMP '2026-07-05 10:00:00',
            3500.00, 10000.00);
    RAISE EXCEPTION 'Проверка активности автомобиля не сработала';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'OK: неактивный автомобиль отклонен';
  END;
END$$;

-- Ожидаемая ошибка: водительское удостоверение истекло до конца аренды.
DO $$
BEGIN
  BEGIN
    INSERT INTO rental(customer_id, car_id, pickup_branch_id, dropoff_branch_id, opened_by_employee_id,
                       status_name, planned_start, planned_end, daily_rate, deposit_amount)
    VALUES (2, 3, 1, 1, 2, 'новый',
            TIMESTAMP '2026-08-01 10:00:00', TIMESTAMP '2026-08-05 10:00:00',
            3500.00, 10000.00);
    RAISE EXCEPTION 'Проверка срока водительского удостоверения не сработала';
  EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'OK: аренда с истекшими правами отклонена';
  END;
END$$;

SELECT * FROM v_available_cars_now;
SELECT * FROM v_revenue_by_month;
