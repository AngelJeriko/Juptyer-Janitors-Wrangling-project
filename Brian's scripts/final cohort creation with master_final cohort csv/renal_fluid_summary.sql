-- ------------------------------------------------------------------
-- TITLE: CREATE_RENAL_FLUID_SUMMARY
-- DESCRIPTION: Category 3. Calculates AKI Stage (0-3) and Fluid Balance.
--              Timeframe: First 24 hours of ICU.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS renal_fluid_summary;

CREATE TABLE renal_fluid_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

-- 1. Get Max Creatinine in First 24h
creat_24h AS (
    SELECT 
        le.hadm_id,
        MAX(le.valuenum) as max_creat_24h
    FROM mimiciv_hosp.labevents le
    JOIN icu_anchor a ON le.hadm_id = a.hadm_id
    WHERE le.itemid = 50912 -- Creatinine
      AND le.charttime >= (a.icu_start_time - INTERVAL '6 hours') 
      AND le.charttime <= (a.icu_start_time + INTERVAL '24 hours')
    GROUP BY le.hadm_id
),

-- 2. Get Urine Output in First 24h
uo_24h AS (
    SELECT 
        oe.hadm_id,
        SUM(oe.value) as urine_output_24h
    FROM mimiciv_icu.outputevents oe
    JOIN icu_anchor a ON oe.hadm_id = a.hadm_id
    WHERE oe.charttime >= a.icu_start_time
      AND oe.charttime <= (a.icu_start_time + INTERVAL '24 hours')
    GROUP BY oe.hadm_id
),

-- 3. Get Total Fluids IN (Inputevents + Pre-admission intake if available)
fluids_in AS (
    -- Summing all inputs (IV fluids, meds, blood products)
    SELECT 
        ie.hadm_id,
        SUM(amount) as total_fluid_intake_24h
    FROM mimiciv_icu.inputevents ie
    JOIN icu_anchor a ON ie.hadm_id = a.hadm_id
    WHERE ie.starttime >= a.icu_start_time
      AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours')
      AND amount > 0
    GROUP BY ie.hadm_id
)

SELECT 
    p.subject_id,
    p.hadm_id,
    
    -- Fluid Metrics
    COALESCE(uo.urine_output_24h, 0) as urine_output_24h,
    COALESCE(fi.total_fluid_intake_24h, 0) as total_fluid_intake_24h,
    (COALESCE(fi.total_fluid_intake_24h, 0) - COALESCE(uo.urine_output_24h, 0)) as fluid_balance_24h,
    
    -- AKI Calculation (KDIGO)
    -- Compare Max 24h Creat vs Baseline Creat (from Patients table)
    CASE 
        -- Stage 3
        WHEN c.max_creat_24h >= (p.baseline_creatinine * 3.0) THEN 3
        WHEN c.max_creat_24h >= 4.0 THEN 3
        -- Stage 2
        WHEN c.max_creat_24h >= (p.baseline_creatinine * 2.0) THEN 2
        -- Stage 1
        WHEN c.max_creat_24h >= (p.baseline_creatinine * 1.5) THEN 1
        WHEN c.max_creat_24h >= (p.baseline_creatinine + 0.3) THEN 1
        -- No AKI
        ELSE 0 
    END as aki_stage_24h,

    -- Binary Flag
    CASE 
        WHEN c.max_creat_24h >= (p.baseline_creatinine * 1.5) OR c.max_creat_24h >= (p.baseline_creatinine + 0.3) THEN 1 
        ELSE 0 
    END as aki_flag

FROM Patients p
LEFT JOIN creat_24h c ON p.hadm_id = c.hadm_id
LEFT JOIN uo_24h uo ON p.hadm_id = uo.hadm_id
LEFT JOIN fluids_in fi ON p.hadm_id = fi.hadm_id
ORDER BY p.subject_id;