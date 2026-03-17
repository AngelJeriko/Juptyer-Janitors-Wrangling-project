-- ------------------------------------------------------------------
-- TITLE: CREATE_LAB_VITAL_DRAGNET_NORMALIZED
-- DESCRIPTION: Category 5. Broad Labs & Vitals.
--              FEATURE: Normalizes Temperature to Celsius (C) 
--              row-by-row BEFORE aggregation to ensure correct SD.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS lab_vital_dragnet;

CREATE TABLE lab_vital_dragnet AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

-- 5.1 BROAD ADMISSION LABS (Unchanged)
labs_raw AS (
    SELECT 
        le.hadm_id,
        -- Chemistry
        ROUND(CAST(AVG(CASE WHEN itemid = 50983 THEN valuenum END) AS NUMERIC), 1) as sodium_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50971 THEN valuenum END) AS NUMERIC), 1) as potassium_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50806 THEN valuenum END) AS NUMERIC), 1) as chloride_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50882 THEN valuenum END) AS NUMERIC), 1) as bicarbonate_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50868 THEN valuenum END) AS NUMERIC), 1) as aniongap_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50931 THEN valuenum END) AS NUMERIC), 1) as glucose_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 51006 THEN valuenum END) AS NUMERIC), 1) as bun_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50893 THEN valuenum END) AS NUMERIC), 1) as calcium_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50960 THEN valuenum END) AS NUMERIC), 1) as magnesium_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50970 THEN valuenum END) AS NUMERIC), 1) as phosphate_mean,
        -- Hematology
        ROUND(CAST(AVG(CASE WHEN itemid = 51301 THEN valuenum END) AS NUMERIC), 1) as wbc_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 51265 THEN valuenum END) AS NUMERIC), 0) as platelets_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 51277 THEN valuenum END) AS NUMERIC), 1) as rdw_mean,
        -- Coagulation
        ROUND(CAST(AVG(CASE WHEN itemid = 51274 THEN valuenum END) AS NUMERIC), 1) as pt_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 51237 THEN valuenum END) AS NUMERIC), 1) as inr_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 51214 THEN valuenum END) AS NUMERIC), 1) as fibrinogen_mean,
        -- Liver/Shock
        ROUND(CAST(AVG(CASE WHEN itemid = 50813 THEN valuenum END) AS NUMERIC), 1) as lactate_mean,
        MAX(CASE WHEN itemid = 50813 THEN valuenum END) as lactate_max,
        ROUND(CAST(AVG(CASE WHEN itemid = 50885 THEN valuenum END) AS NUMERIC), 1) as bilirubin_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50862 THEN valuenum END) AS NUMERIC), 1) as albumin_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50861 THEN valuenum END) AS NUMERIC), 0) as alt_mean,
        ROUND(CAST(AVG(CASE WHEN itemid = 50863 THEN valuenum END) AS NUMERIC), 0) as ast_mean
    FROM mimiciv_hosp.labevents le
    JOIN icu_anchor a ON le.hadm_id = a.hadm_id
    WHERE le.charttime >= (a.icu_start_time - INTERVAL '6 hours')
      AND le.charttime <= (a.icu_start_time + INTERVAL '24 hours')
    GROUP BY le.hadm_id
),

-- 5.2 TEMP PRE-PROCESSING (The Fix)
temp_clean AS (
    SELECT 
        ce.hadm_id,
        CASE 
            -- If value > 80, assume Fahrenheit and convert to C
            WHEN ce.valuenum > 80 THEN (ce.valuenum - 32) * 5.0/9.0
            -- Otherwise assume Celsius
            ELSE ce.valuenum 
        END as temp_c
    FROM mimiciv_icu.chartevents ce
    JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.itemid IN (223762, 223761) -- C and F codes
      AND ce.valuenum > 0 -- Exclude zeros
),

-- 5.3 VITAL SIGN AGGREGATION
vitals_variability AS (
    SELECT 
        ce.hadm_id,
        -- Heart Rate
        ROUND(CAST(AVG(CASE WHEN itemid = 220045 THEN valuenum END) AS NUMERIC), 1) as hr_mean,
        ROUND(CAST(STDDEV(CASE WHEN itemid = 220045 THEN valuenum END) AS NUMERIC), 1) as hr_sd,
        -- Resp Rate
        ROUND(CAST(AVG(CASE WHEN itemid = 220210 THEN valuenum END) AS NUMERIC), 1) as rr_mean,
        ROUND(CAST(STDDEV(CASE WHEN itemid = 220210 THEN valuenum END) AS NUMERIC), 1) as rr_sd,
        -- SpO2
        ROUND(CAST(AVG(CASE WHEN itemid = 220277 THEN valuenum END) AS NUMERIC), 1) as spo2_mean,
        ROUND(CAST(STDDEV(CASE WHEN itemid = 220277 THEN valuenum END) AS NUMERIC), 1) as spo2_sd
    FROM mimiciv_icu.chartevents ce
    JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.charttime >= a.icu_start_time
      AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND ce.itemid IN (220045, 220210, 220277)
    GROUP BY ce.hadm_id
),

-- 5.4 TEMP AGGREGATION (From Clean Table)
temp_agg AS (
    SELECT 
        hadm_id,
        ROUND(CAST(AVG(temp_c) AS NUMERIC), 1) as temp_mean,
        ROUND(CAST(STDDEV(temp_c) AS NUMERIC), 1) as temp_sd
    FROM temp_clean
    GROUP BY hadm_id
)

-- FINAL MERGE
SELECT 
    p.subject_id,
    p.hadm_id,
    -- Labs
    l.sodium_mean, l.potassium_mean, l.chloride_mean, l.bicarbonate_mean,
    l.aniongap_mean, l.glucose_mean, l.bun_mean, l.calcium_mean,
    l.magnesium_mean, l.phosphate_mean, l.wbc_mean, l.platelets_mean,
    l.rdw_mean, l.pt_mean, l.inr_mean, l.fibrinogen_mean,
    l.lactate_mean, l.lactate_max, l.bilirubin_mean, l.albumin_mean,
    l.alt_mean, l.ast_mean,
    -- Vitals
    v.hr_mean, v.hr_sd, v.rr_mean, v.rr_sd,
    v.spo2_mean, v.spo2_sd, 
    -- Temp (Now guaranteed C)
    t.temp_mean, t.temp_sd
FROM Patients p
LEFT JOIN labs_raw l ON p.hadm_id = l.hadm_id
LEFT JOIN vitals_variability v ON p.hadm_id = v.hadm_id
LEFT JOIN temp_agg t ON p.hadm_id = t.hadm_id
ORDER BY p.subject_id;