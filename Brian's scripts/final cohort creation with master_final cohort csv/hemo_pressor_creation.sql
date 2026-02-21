-- ------------------------------------------------------------------
-- TITLE: CREATE_HEMO_PRESSOR_SUMMARY_V4 (The Final Integrity Fix)
-- DESCRIPTION: Ensures MIN and AVG both respect the 40-180 mmHg window.
--              Adds MAP Variance for ML clustering.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS hemo_pressor_summary;

CREATE TABLE hemo_pressor_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

clean_vitals AS (
    -- 1. Create a "Pure" stream of physiological data
    SELECT 
        ce.hadm_id,
        ce.valuenum as map_val,
        ce.charttime
    FROM mimiciv_icu.chartevents ce
    JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid IN (220052, 220181, 225312)
      AND ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.valuenum BETWEEN 40 AND 180 -- THE FILTER
),

clean_hr AS (
    SELECT 
        ce.hadm_id,
        ce.valuenum as hr_val,
        ce.charttime
    FROM mimiciv_icu.chartevents ce
    JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid = 220045
      AND ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.valuenum BETWEEN 30 AND 220
),

map_agg AS (
    -- 2. Aggregate from the CLEAN stream only
    SELECT 
        hadm_id,
        ROUND(CAST(AVG(map_val) AS NUMERIC), 1) as map_avg_24h,
        MIN(map_val) as map_min_24h,
        ROUND(CAST(STDDEV(map_val) AS NUMERIC), 1) as map_stddev_24h,
        SUM(CASE WHEN map_val < 65 THEN 1 ELSE 0 END) as map_count_below_65,
        SUM(CASE WHEN map_val < 75 THEN 1 ELSE 0 END) as map_count_below_75
    FROM clean_vitals
    GROUP BY hadm_id
),

hr_agg AS (
    SELECT DISTINCT ON (hadm_id)
        hadm_id, hr_val as hr_admit
    FROM clean_hr
    ORDER BY hadm_id, charttime ASC
),

pressor_agg AS (
    SELECT 
        ie.hadm_id,
        SUM(EXTRACT(EPOCH FROM (ie.endtime - ie.starttime))/3600.0) as pressor_hours,
        MAX(CASE WHEN ie.rate > 0 THEN ie.rate 
                 WHEN ie.amount > 0 THEN 0.01 
                 ELSE 0 END) as max_pressor_dose
    FROM mimiciv_icu.inputevents ie
    JOIN Patients p ON ie.hadm_id = p.hadm_id
    JOIN icu_anchor a ON ie.hadm_id = a.hadm_id
    WHERE ie.starttime >= a.icu_start_time
      AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ie.itemid IN (221906, 221289, 222315, 221749, 221662)
    GROUP BY ie.hadm_id
)

-- 3. FINAL MERGE
SELECT 
    p.subject_id,
    p.hadm_id,
    COALESCE(m.map_avg_24h, 0) as map_avg_24h,
    COALESCE(m.map_min_24h, 0) as map_min_24h,
    COALESCE(m.map_stddev_24h, 0) as map_variance,
    COALESCE(m.map_count_below_65, 0) as map_count_below_65,
    COALESCE(m.map_count_below_75, 0) as map_count_below_75,
    COALESCE(h.hr_admit, 0) as hr_admit,
    CASE WHEN pr.pressor_hours > 0 THEN 1 ELSE 0 END as vasopressor_flag,
    ROUND(CAST(COALESCE(pr.pressor_hours, 0) AS NUMERIC), 1) as pressor_hours,
    COALESCE(pr.max_pressor_dose, 0) as max_pressor_dose
FROM Patients p
LEFT JOIN map_agg m ON p.hadm_id = m.hadm_id
LEFT JOIN hr_agg h ON p.hadm_id = h.hadm_id
LEFT JOIN pressor_agg pr ON p.hadm_id = pr.hadm_id
ORDER BY p.subject_id;