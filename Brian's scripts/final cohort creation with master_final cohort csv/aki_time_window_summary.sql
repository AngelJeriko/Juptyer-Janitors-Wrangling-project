DROP TABLE IF EXISTS aki_time_windows_summary;

CREATE TABLE aki_time_windows_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, p.baseline_creatinine, MIN(ie.intime) as icu_start_time
    FROM Patients p
    JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id
    GROUP BY p.hadm_id, p.baseline_creatinine
),
daily_cr AS (
    SELECT 
        a.hadm_id,
        a.baseline_creatinine,
        CEIL(EXTRACT(EPOCH FROM (le.charttime - a.icu_start_time))/86400.0) as icu_day,
        MAX(le.valuenum) as max_cr_day
    FROM icu_anchor a
    JOIN mimiciv_hosp.labevents le ON a.hadm_id = le.hadm_id
    WHERE le.itemid = 50912 
      AND le.charttime > a.icu_start_time
      AND le.charttime <= (a.icu_start_time + INTERVAL '7 days')
    GROUP BY a.hadm_id, a.baseline_creatinine, 
             CEIL(EXTRACT(EPOCH FROM (le.charttime - a.icu_start_time))/86400.0)
),
aki_days AS (
    SELECT 
        hadm_id, icu_day, max_cr_day,
        CASE 
            WHEN max_cr_day >= (baseline_creatinine * 1.5) OR max_cr_day >= (baseline_creatinine + 0.3) THEN 1 
            ELSE 0 
        END as aki_met
    FROM daily_cr
)
SELECT 
    hadm_id,
    MAX(CASE WHEN icu_day = 1 THEN aki_met ELSE 0 END) as aki_24h_flag,
    MAX(CASE WHEN icu_day <= 3 THEN aki_met ELSE 0 END) as aki_72h_flag,
    MAX(CASE WHEN icu_day <= 7 THEN aki_met ELSE 0 END) as aki_7day_flag,
    MIN(CASE WHEN aki_met = 1 THEN icu_day END) as time_to_aki_days
FROM aki_days
GROUP BY hadm_id;