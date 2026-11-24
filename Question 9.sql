DROP VIEW IF EXISTS v_farmer_amount_due CASCADE;
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(12, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Unsupported maize grade: %', p_grade;
    END IF;

    RETURN CASE p_grade
        WHEN 'A' THEN 5.00
        WHEN 'B' THEN 4.00
        WHEN 'C' THEN 3.00
    END;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     CHAR,
    p_weight    NUMERIC(12, 2),
    p_date      DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight_kg: %', p_weight;
    END IF;

    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 1.00, 1.00, COALESCE(p_date, CURRENT_DATE), FALSE);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_set_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC(10, 2);
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive, got %', NEW.weight_kg;
    END IF;

    v_rate := fn_maize_rate(NEW.grade);
    NEW.unit_rate   := v_rate;
    NEW.total_value := ROUND(NEW.weight_kg * v_rate, 2)::NUMERIC(12, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_set_delivery_pricing();

-- (a) Seed Farmers & Load 6 Deliveries After Installing Trigger
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Benson Mwape'),
    ('F002', 'Esther Banda'),
    ('F003', 'Patrick Zulu');

INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES
    (1, 'A', 200.00, 1.00, 1.00, '2026-11-22', TRUE),
    (1, 'B', 150.00, 1.00, 1.00, '2026-11-22', FALSE),
    (2, 'C', 300.00, 1.00, 1.00, '2026-11-23', FALSE),
    (2, 'A', 100.00, 1.00, 1.00, '2026-11-23', TRUE),
    (3, 'B', 250.00, 1.00, 1.00, '2026-11-23', FALSE),
    (3, 'C', 120.00, 1.00, 1.00, '2026-11-23', TRUE);

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00) AS unpaid_amount
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- (f) Index & EXPLAIN
CREATE INDEX idx_deliveries_farmer_delivered_on
ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Refresh Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value  NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(DATE '2026-11-23');
SELECT * FROM daily_purchases;

