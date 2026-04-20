-- ------------------------------------------------------------------
-- TITLE: DAY0_VS_RECENT_AUDIT
-- DESCRIPTION: Checks if Day 0 labs are hemodiluted compared to baseline
-- ------------------------------------------------------------------

WITH recent_labs AS (
    SELECT 
        vc.hadm_id,
        MAX(le.valuenum) as recent_cr 
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912
        AND le.valuenum IS NOT NULL
        -- The Gold Standard Window (Day -1 to -7)
        AND le.charttime::DATE >= (vc.admittime::DATE - 7)
        AND le.charttime::DATE < vc.admittime::DATE 
    GROUP BY vc.hadm_id
),
day0_labs AS (
    SELECT 
        vc.hadm_id,
        -- Take the FIRST lab of the day to try and catch them pre-fluids
        -- (Using MIN(charttime) logic would be better, but MAX val is safer for risk)
        MAX(le.valuenum) as day0_cr
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912
        AND le.valuenum IS NOT NULL
        -- Strictly Day 0
        AND le.charttime::DATE = vc.admittime::DATE
    GROUP BY vc.hadm_id
)

SELECT 
    COUNT(*) as n_overlap_patients,

    -- 1. DRIFT METRICS (Day 0 - Recent)
    -- Negative result = Day 0 is lower (Dilution)
    ROUND(AVG(day0.day0_cr - recent.recent_cr)::NUMERIC, 3) as mean_drift_mg_dl,
    ROUND(AVG(ABS(day0.day0_cr - recent.recent_cr))::NUMERIC, 3) as mean_absolute_error,

    -- 2. THE "HIDDEN CKD" CHECK (The most dangerous metric)
    -- Scenario: Recent was High (>=1.3), but Day 0 looks Normal (<1.3)
    SUM(CASE 
        WHEN recent.recent_cr >= 1.3 AND day0.day0_cr < 1.3 THEN 1 ELSE 0 
    END) as count_diluted_normal,
    
    ROUND(
        (SUM(CASE WHEN recent.recent_cr >= 1.3 AND day0.day0_cr < 1.3 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))::NUMERIC, 
        1
    ) as pct_diluted_normal

FROM recent_labs recent
INNER JOIN day0_labs day0 ON recent.hadm_id = day0.hadm_id;