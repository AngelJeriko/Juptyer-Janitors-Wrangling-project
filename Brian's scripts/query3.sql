-- ------------------------------------------------------------------
-- TITLE: EXTRACT_RAW_CREATININE
-- DESCRIPTION: Pulls all serum creatinine values (Pre and Post op)
-- ------------------------------------------------------------------

SELECT 
    vc.subject_id,
    vc.hadm_id,
    vc.group_type,
    le.charttime,
    le.valuenum as creatinine_value
FROM vascular_cohort vc
INNER JOIN mimiciv_hosp.labevents le
    ON vc.subject_id = le.subject_id -- Match on Patient, not just Admission (for Baseline lookback)
WHERE 
    le.itemid = 50912 -- Serum Creatinine
    AND le.valuenum IS NOT NULL
    -- Grab data from 1 year before admission (for Baseline) up to discharge
    AND le.charttime BETWEEN (vc.admittime - INTERVAL '365 days') AND vc.dischtime
ORDER BY vc.subject_id, le.charttime;