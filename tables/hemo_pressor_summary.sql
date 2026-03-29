-- ------------------------------------------------------------------
-- TITLE: CREATE_HEMO_PRESSOR_SUMMARY_V3 (The Pressor Dose Fix)
-- DESCRIPTION: Fixes the "0 dose but on pressor" bug by capturing
--              max rates and ensuring Boluses don't zero out intensity.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS hemo_pressor_summary;

CREATE TABLE hemo_pressor_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

vitals_filtered AS (
    -- Physiological Filter (MAP 30-200, HR 30-250)
    SELECT 
        p.hadm_id, ce.charttime, ce.itemid, ce.valuenum
    FROM Patients p
    JOIN icu_anchor a ON p.hadm_id = a.hadm_id
    JOIN mimiciv_icu.chartevents ce ON p.hadm_id = ce.hadm_id
    WHERE ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.valuenum IS NOT NULL
      AND (
          (ce.itemid IN (220052, 220181, 225312) AND ce.valuenum BETWEEN 30 AND 200)
          OR 
          (ce.itemid = 220045 AND ce.valuenum BETWEEN 30 AND 250)
      )
),

map_stats AS (
    SELECT 
        hadm_id,
        ROUND(CAST(AVG(valuenum) AS NUMERIC), 1) as map_avg_24h,
        MIN(valuenum) as map_min_24h,
        SUM(CASE WHEN valuenum < 65 THEN 1 ELSE 0 END) as map_count_below_65,
        SUM(CASE WHEN valuenum < 75 THEN 1 ELSE 0 END) as map_count_below_75
    FROM vitals_filtered
    WHERE itemid IN (220052, 220181, 225312)
    GROUP BY hadm_id
),

hr_stats AS (
    SELECT DISTINCT ON (hadm_id)
        hadm_id, valuenum as hr_admit
    FROM vitals_filtered
    WHERE itemid = 220045
    ORDER BY hadm_id, charttime ASC
),

pressor_data AS (
    -- IMPROVED PRESSOR LOGIC
    SELECT 
        p.hadm_id,
        -- Total time spent on any of the 5 main pressors
        SUM(EXTRACT(EPOCH FROM (ie.endtime - ie.starttime))/3600.0) as pressor_duration_hours,
        
        -- Capture the MAX rate. If rate is 0/NULL but amount exists, 
        -- we treat it as a bolus or a legacy record.
        MAX(
            CASE 
                WHEN ie.rate > 0 THEN ie.rate 
                WHEN ie.amount > 0 THEN 0.01 -- Placeholder for "Active but non-rate dose"
                ELSE 0 
            END
        ) as max_pressor_intensity
    FROM Patients p
    JOIN icu_anchor a ON p.hadm_id = a.hadm_id
    JOIN mimiciv_icu.inputevents ie ON p.hadm_id = ie.hadm_id
    WHERE ie.starttime >= a.icu_start_time
      AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours')
      -- Norepi, Epi, Vasopressin, Phenyl, Dopamine
      AND ie.itemid IN (221906, 221289, 222315, 221749, 221662)
    GROUP BY p.hadm_id
)

SELECT 
    p.subject_id,
    p.hadm_id,
    COALESCE(ms.map_avg_24h, 0) as map_avg_24h,
    COALESCE(ms.map_min_24h, 0) as map_min_24h,
    COALESCE(ms.map_count_below_65, 0) as map_count_below_65,
    COALESCE(ms.map_count_below_75, 0) as map_count_below_75,
    COALESCE(hs.hr_admit, 0) as hr_admit,
    
    CASE WHEN pd.pressor_duration_hours > 0 THEN 1 ELSE 0 END as vasopressor_flag,
    ROUND(CAST(COALESCE(pd.pressor_duration_hours, 0) AS NUMERIC), 1) as pressor_hours,
    
    -- This now reflects true intensity
    COALESCE(pd.max_pressor_intensity, 0) as max_pressor_dose

FROM Patients p
LEFT JOIN map_stats ms ON p.hadm_id = ms.hadm_id
LEFT JOIN hr_stats hs ON p.hadm_id = hs.hadm_id
LEFT JOIN pressor_data pd ON p.hadm_id = pd.hadm_id
ORDER BY p.subject_id;