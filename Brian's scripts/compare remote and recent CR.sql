-- ------------------------------------------------------------------
-- TITLE: CREATININE_DRIFT_ANALYSIS (FIXED)
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
        AND le.charttime::DATE >= (vc.admittime::DATE - 7)
        AND le.charttime::DATE < vc.admittime::DATE 
    GROUP BY vc.hadm_id
),
remote_labs AS (
    SELECT 
        vc.hadm_id,
        MAX(le.valuenum) as remote_cr
    FROM vascular_cohort vc
    JOIN mimiciv_hosp.labevents le 
        ON vc.subject_id = le.subject_id 
        AND le.itemid = 50912
        AND le.valuenum IS NOT NULL
        AND le.charttime::DATE >= (vc.admittime::DATE - 365)
        AND le.charttime::DATE <= (vc.admittime::DATE - 8)
    GROUP BY vc.hadm_id
)

SELECT 
    COUNT(*) as n_overlap_patients,

    -- 1. DRIFT METRICS (Fixed with ::NUMERIC cast)
    ROUND(AVG(recent.recent_cr - remote.remote_cr)::NUMERIC, 3) as mean_drift_mg_dl,
    ROUND(AVG(ABS(recent.recent_cr - remote.remote_cr))::NUMERIC, 3) as mean_absolute_error,

    -- 2. CLINICAL RISK (KDIGO Standard: Change >= 0.3 is significant)
    SUM(CASE 
        WHEN ABS(recent.recent_cr - remote.remote_cr) >= 0.3 THEN 1 ELSE 0 
    END) as count_significant_change,
    
    ROUND(
        (SUM(CASE WHEN ABS(recent.recent_cr - remote.remote_cr) >= 0.3 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))::NUMERIC, 
        1
    ) as pct_significant_change,

    -- 3. THE "MISSED DIAGNOSIS" CHECK
    SUM(CASE 
        WHEN remote.remote_cr < 1.3 AND recent.recent_cr >= 1.3 THEN 1 ELSE 0 
    END) as count_newly_abnormal,

     ROUND(
        (SUM(CASE WHEN remote.remote_cr < 1.3 AND recent.recent_cr >= 1.3 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))::NUMERIC, 
        1
    ) as pct_newly_abnormal

FROM recent_labs recent
INNER JOIN remote_labs remote ON recent.hadm_id = remote.hadm_id;