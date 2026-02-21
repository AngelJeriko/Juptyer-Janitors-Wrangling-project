-- ------------------------------------------------------------------
-- TITLE: CALCULATE_TRUE_MAP_TWA
-- DESCRIPTION: Calculates Time-Weighted Average (TWA) MAP.
--              Eliminates sampling bias (e.g., q5min readings during crash).
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS map_twa_summary;

CREATE TABLE map_twa_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

clean_vitals AS (
    -- 1. Get raw stream (same filter as before)
    SELECT 
        ce.hadm_id,
        ce.charttime,
        ce.valuenum as map_val
    FROM mimiciv_icu.chartevents ce
    JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid IN (220052, 220181, 225312)
      AND ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.valuenum BETWEEN 40 AND 180
),

time_intervals AS (
    -- 2. Calculate duration until next reading
    SELECT 
        hadm_id,
        map_val,
        charttime,
        LEAD(charttime) OVER (PARTITION BY hadm_id ORDER BY charttime) as next_charttime,
        EXTRACT(EPOCH FROM (LEAD(charttime) OVER (PARTITION BY hadm_id ORDER BY charttime) - charttime)) / 3600.0 as duration_hours
    FROM clean_vitals
)

-- 3. Calculate Weighted Average
SELECT 
    hadm_id,
    -- Sum of (Value * Duration) / Total Duration
    ROUND(CAST(
        SUM(map_val * duration_hours) / NULLIF(SUM(duration_hours), 0) 
    AS NUMERIC), 1) as map_twa_24h
FROM time_intervals
WHERE duration_hours IS NOT NULL -- Drop the last reading (no duration)
  AND duration_hours < 4 -- Exclude massive gaps (>4h) which imply missing data
GROUP BY hadm_id;