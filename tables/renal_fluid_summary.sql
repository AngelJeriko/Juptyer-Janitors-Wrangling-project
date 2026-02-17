-- ------------------------------------------------------------------
-- TITLE: CREATE_RENAL_FLUID_SUMMARY_FINAL
-- DESCRIPTION: Calculates 24h Fluids & AKI Outcomes for the CLEAN ICU COHORT.
--              Logic: "Dragnet" (All mLs) + 4h Lookback for OR Bags.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS renal_fluid_summary;

CREATE TABLE renal_fluid_summary AS
WITH icu_anchor AS (
    -- 1. GET ICU START TIME
    -- Relies on your clean 'Patients' table (N ~ 1,132)
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id
),

fluid_inputs AS (
    -- 2. SUM FLUIDS (The "Dragnet")
    SELECT 
        p.hadm_id,
        SUM(
            CASE 
                -- Case A: Standard Bolus/Bag (Amount is known)
                WHEN ie.amount > 0 THEN ie.amount
                
                -- Case B: Rate-Based Infusion (Rate * Duration)
                -- Catches rows where Amount is missing/zero but Rate is valid
                WHEN ie.rate > 0 AND (ie.amount IS NULL OR ie.amount = 0) THEN 
                     (ie.rate * (EXTRACT(EPOCH FROM (ie.endtime - ie.starttime))/3600.0))
                
                ELSE 0 
            END
        ) as total_fluids_in_24h
    FROM Patients p
    JOIN icu_anchor a ON p.hadm_id = a.hadm_id
    JOIN mimiciv_icu.inputevents ie ON p.hadm_id = ie.hadm_id
    WHERE 
      -- TIME WINDOW: ICU Entry + 24h (with -4h lookback for bags hung in OR)
      ie.starttime >= (a.icu_start_time - INTERVAL '4 hours')
      AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours')
      
      -- LOGIC: The fluid must have been running AFTER they arrived
      AND ie.endtime >= a.icu_start_time
      
      -- UNIT FILTER: Capture anything liquid (mL or L)
      AND ie.amountuom IN ('ml', 'mL', 'l', 'L')
    GROUP BY p.hadm_id
),

fluid_outputs AS (
    -- 3. SUM URINE OUTPUT
    SELECT 
        p.hadm_id,
        SUM(oe.value) as urine_output_24h
    FROM Patients p
    JOIN icu_anchor a ON p.hadm_id = a.hadm_id
    JOIN mimiciv_icu.outputevents oe ON p.hadm_id = oe.hadm_id
    WHERE oe.charttime >= a.icu_start_time 
      AND oe.charttime <= (a.icu_start_time + INTERVAL '24 hours')
      -- Standard Foley/Void ItemIDs
      AND oe.itemid IN (226559, 226560, 226561, 226584, 226563, 226564, 226565, 226567, 226557, 226558)
    GROUP BY p.hadm_id
),

post_op_creatinine AS (
    -- 4. CALCULATE AKI OUTCOMES (7-Day Window)
    SELECT 
        p.hadm_id,
        p.baseline_creatinine,
        MAX(le.valuenum) as max_creatinine_7day,
        
        -- Find First Day of Onset (for Survival Analysis)
        MIN(CASE 
            WHEN (le.valuenum / p.baseline_creatinine) >= 1.5 
              OR (le.valuenum - p.baseline_creatinine) >= 0.3 
            THEN DATE_PART('day', le.charttime - p.admittime)
            ELSE NULL 
        END) as day_of_aki_onset
        
    FROM Patients p
    JOIN mimiciv_hosp.labevents le 
        ON p.subject_id = le.subject_id
        AND le.itemid = 50912 -- Serum Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= p.admittime
        AND le.charttime <= (p.admittime + INTERVAL '7 days')
    GROUP BY p.hadm_id, p.baseline_creatinine
)

-- 5. FINAL ASSEMBLY
SELECT 
    p.subject_id,
    p.hadm_id,
    
    -- FLUIDS (Rounded to Integers)
    CAST(COALESCE(fi.total_fluids_in_24h, 0) AS INTEGER) as total_fluids_in_24h,
    CAST(COALESCE(fo.urine_output_24h, 0) AS INTEGER) as urine_output_24h,
    CAST((COALESCE(fi.total_fluids_in_24h, 0) - COALESCE(fo.urine_output_24h, 0)) AS INTEGER) as fluid_balance_24h,
    
    -- CREATININE (Decimals)
    poc.max_creatinine_7day,
    p.baseline_creatinine,
    
    -- AKI STAGING (KDIGO Criteria)
    CASE 
        WHEN (poc.max_creatinine_7day / p.baseline_creatinine) >= 3.0 
          OR (poc.max_creatinine_7day >= 4.0) THEN 3
        WHEN (poc.max_creatinine_7day / p.baseline_creatinine) >= 2.0 THEN 2
        WHEN (poc.max_creatinine_7day / p.baseline_creatinine) >= 1.5 
          OR (poc.max_creatinine_7day - p.baseline_creatinine) >= 0.3 THEN 1
        ELSE 0 
    END as aki_stage,
    
    -- BINARY OUTCOME
    CASE 
        WHEN (poc.max_creatinine_7day / p.baseline_creatinine) >= 1.5 
          OR (poc.max_creatinine_7day - p.baseline_creatinine) >= 0.3 THEN 1 ELSE 0 
    END as aki_binary,
    
    -- SURVIVAL TIME (Censored at 7 days if no event)
    COALESCE(poc.day_of_aki_onset, 7) as time_to_aki_event

FROM Patients p
LEFT JOIN fluid_inputs fi ON p.hadm_id = fi.hadm_id
LEFT JOIN fluid_outputs fo ON p.hadm_id = fo.hadm_id
LEFT JOIN post_op_creatinine poc ON p.hadm_id = poc.hadm_id
ORDER BY p.subject_id;