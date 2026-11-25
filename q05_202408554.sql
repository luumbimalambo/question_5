-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Student: Luumbi Malambo | Student No: 202408554

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    )
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('202400201', 'Anna Chola'),
    ('202400202', 'Brian Daka'),
    ('202400203', 'Carol Ng''andu'),
    ('202400204', 'David Mulenga'),
    ('202400205', 'Evelyn Simfukwe');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),    -- will be FULL
    ('A102', 3),    -- will be PARTLY occupied
    ('A103', 2);    -- will be EMPTY (only an ENDED allocation)

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
    v_capacity INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    RETURN v_capacity - (SELECT COUNT(*) FROM allocations
                         WHERE room_id = p_room_id AND status = 'ACTIVE');  -- ENDED ignored
END;
$$ LANGUAGE plpgsql STABLE;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS TRIGGER AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so concurrent allocations are processed one by one
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- one ACTIVE allocation per student (exclude the row being updated)
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND a.allocation_id <> NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- capacity (exclude the row being updated)
        SELECT COUNT(*) INTO v_others FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id <> NEW.allocation_id;
        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- Extra safety net: a student can never have two ACTIVE rows
CREATE UNIQUE INDEX uq_student_one_active ON allocations (student_id) WHERE status = 'ACTIVE';

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (a) continued: seed allocations (full, partly occupied, empty rooms)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);     -- A101: 2/2 full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);     -- A102: 1/3
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');   -- history only, A103 empty

SELECT * FROM allocations ORDER BY allocation_id;

-- Tests
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;  -- 0, 2, 2
CALL pr_allocate_room(4, 2, CURRENT_DATE);          -- student with ENDED history may be allocated
DO $$
BEGIN
    BEGIN PERFORM fn_free_beds(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(99, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 2, CURRENT_DATE);      -- already ACTIVE
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);      -- room full
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    -- direct SQL is protected by the trigger too
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
-- Releasing a student frees the bed (UPDATE excludes itself in the trigger):
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE allocation_id = 2;
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'  -- keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ----------------------------------------------------------------
-- Occupancy checks only look at ACTIVE rows of one room. A partial index
-- (room_id) WHERE status = 'ACTIVE' is small and ignores ENDED history.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM allocations WHERE room_id = 2 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();    -- rerun replaces values, one row per date and room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_occupancy_daily', '55 23 * * *',
        $$CALL pr_refresh_occupancy()$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
