-- ------------------------------------------------------------------
-- TITLE: STRICT_REMOTE_VS_RECENT_AUDIT
-- DESCRIPTION: Compares 8-90 day labs against the -1 to -7 day Gold Standard
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
        -- Gold Standard Window
        AND le.charttime::DATE >= (vc.admittime::DATE - 7)
        AND le.charttime::DATE < vc.admittime::DATE 
    GROUP BY vc.hadm_id
),
strict_remote_labs AS (
    SELECT 
        vc.hadm_id,
        -- Take the LATEST lab in the window (closest to surgery)
        (ARRAY_AGG(le.valuenum ORDER BY le.charttime DESC))[1] as remote_cr
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912
        AND le.valuenum IS NOT NULL
        -- The "Strict" Window (8 to 90 days)
        AND le.charttime::DATE >= (vc.admittime::DATE - 90)
        AND le.charttime::DATE <= (vc.admittime::DATE - 8)
    GROUP BY vc.hadm_id
)

SELECT 
    COUNT(*) as n_overlap_patients,

    -- 1. ERROR METRICS
    -- Mean Absolute Error: How far off is the "Old" lab on average?
    ROUND(AVG(ABS(rm.remote_cr - rc.recent_cr))::NUMERIC, 3) as mean_absolute_error,
    
    -- Mean Drift: Direction of error (Negative = Old lab was lower/better)
    ROUND(AVG(rm.remote_cr - rc.recent_cr)::NUMERIC, 3) as mean_drift,

    -- 2. CLINICAL IMPACT
    -- How many patients had a clinically significant shift (>0.3)?
    SUM(CASE WHEN ABS(rm.remote_cr - rc.recent_cr) >= 0.3 THEN 1 ELSE 0 END) as count_significant_change,
    
    ROUND(
        (SUM(CASE WHEN ABS(rm.remote_cr - rc.recent_cr) >= 0.3 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))::NUMERIC, 
        1
    ) as pct_significant_change

FROM recent_labs rc
INNER JOIN strict_remote_labs rm ON rc.hadm_id = rm.hadm_id;