-- ============================================================
-- Q4: CLINIC APPOINTMENT SCHEDULING
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE patients (patient_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors  (doctor_id  SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL
        CHECK (slot_time IN ('09:00'::time,'10:00'::time,'11:00'::time,'12:00'::time)),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
-- Safety net against race conditions (the trigger in (d) gives the friendly message)
CREATE UNIQUE INDEX ux_active_slot
ON appointments(doctor_id, appointment_day, slot_time) WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id: %', p_doctor_id;
    END IF;
    RETURN (SELECT COUNT(*)::INT FROM appointments
            WHERE doctor_id = p_doctor_id AND appointment_day = p_day
              AND status <> 'CANCELLED');       -- zero when no bookings
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is missing or in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::time,'10:00'::time,'11:00'::time,'12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot: %', p_slot;
    END IF;

    INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');  -- clash check is in the trigger
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_slot_clash() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
        WHERE a.doctor_id = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time = NEW.slot_time
          AND a.status <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)  -- exclude self on UPDATE
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
              NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_slot_clash();

-- ---------- (a) SEED DATA ----------
INSERT INTO patients(full_name) VALUES ('Patient One'), ('Patient Two'), ('Patient Three');
INSERT INTO doctors(full_name)  VALUES ('Dr Phiri'), ('Dr Zulu'), ('Dr Tembo');

INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE,   '09:00', 'BOOKED'),
 (2, 1, CURRENT_DATE,   '10:00', 'BOOKED'),
 (3, 2, CURRENT_DATE,   '09:00', 'BOOKED'),
 (1, 2, CURRENT_DATE-1, '11:00', 'ATTENDED'),
 (2, 3, CURRENT_DATE-1, '12:00', 'CANCELLED'),
 (3, 3, CURRENT_DATE-1, '12:00', 'BOOKED');   -- allowed: the earlier one is cancelled

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- ---------- (f) INDEX ----------
-- Non-unique: a doctor can have several appointments on one day.
-- Day first because it is the most selective filter for a daily schedule.
CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day, doctor_id);

-- SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;

-- ---------- (g) SCHEDULED JOB ----------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *',
       $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);