-- ------------------------------------------------------------------
-- TITLE: CREATE_SAFETY_SURVIVAL_SUMMARY_V3 (Outlier Protected)
-- DESCRIPTION: Applies clinical caps to prevent extreme outliers from
--              warping statistical models (Troponin capped at 50).
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS safety_survival_summary;

CREATE TABLE safety_survival_summary AS
WITH safety_labs AS (
    SELECT 
        le.hadm_id,
        -- CAP Troponin at 50 to prevent extreme skew (e.g., 15,399)
        CASE 
            WHEN MAX(CASE WHEN le.itemid IN (51002, 51003, 50963) THEN le.valuenum END) > 50 THEN 50
            ELSE MAX(CASE WHEN le.itemid IN (51002, 51003, 50963) THEN le.valuenum END)
        END as peak_troponin_48h,
        
        -- MIN Hemoglobin (no cap needed, but usually 3-20 range)
        MIN(CASE WHEN le.itemid = 51222 THEN le.valuenum END) as min_hgb_48h
    FROM mimiciv_hosp.labevents le
    JOIN Patients p ON le.hadm_id = p.hadm_id
    WHERE le.charttime >= p.admittime 
      AND le.charttime <= (p.admittime + INTERVAL '48 hours')
    GROUP BY le.hadm_id
),

transfusion_events AS (
    SELECT 
        ie.hadm_id,
        MAX(1) as transfusion_flag
    FROM mimiciv_icu.inputevents ie
    JOIN Patients p ON ie.hadm_id = p.hadm_id
    WHERE ie.itemid = 225168 -- PRBCs
      AND ie.amount > 0
      AND ie.starttime >= p.admittime 
      AND ie.starttime <= (p.admittime + INTERVAL '48 hours')
    GROUP BY ie.hadm_id
),

survival_data AS (
    SELECT 
        a.hadm_id,
        a.hospital_expire_flag,
        a.discharge_location,
        a.deathtime as hospital_death_timestamp,
        pat.dod as date_of_death,
        CASE 
            WHEN a.hospital_expire_flag = 1 THEN 
                EXTRACT(EPOCH FROM (COALESCE(a.deathtime, pat.dod::timestamp) - a.admittime))/86400.0
            ELSE NULL 
        END as time_to_death_days,
        EXTRACT(EPOCH FROM (a.dischtime - a.admittime))/86400.0 as hospital_los_days
    FROM mimiciv_hosp.admissions a
    JOIN mimiciv_hosp.patients pat ON a.subject_id = pat.subject_id
    JOIN Patients p ON a.hadm_id = p.hadm_id
),

icu_los AS (
    SELECT hadm_id, SUM(los) as icu_los_total FROM mimiciv_icu.icustays GROUP BY hadm_id
)

SELECT 
    p.subject_id,
    p.hadm_id,
    COALESCE(sl.peak_troponin_48h, 0) as peak_troponin,
    CASE WHEN sl.peak_troponin_48h > 0.04 THEN 1 ELSE 0 END as myocardial_injury_flag,
    sl.min_hgb_48h,
    COALESCE(te.transfusion_flag, 0) as transfusion_event,
    sd.hospital_expire_flag,
    sd.discharge_location,
    sd.hospital_death_timestamp,
    sd.date_of_death,
    ROUND(CAST(sd.time_to_death_days AS NUMERIC), 2) as time_to_death_days,
    ROUND(CAST(COALESCE(i.icu_los_total, 0) AS NUMERIC), 2) as icu_los_days,
    ROUND(CAST(sd.hospital_los_days AS NUMERIC), 2) as hospital_los_days
FROM Patients p
LEFT JOIN safety_labs sl ON p.hadm_id = sl.hadm_id
LEFT JOIN transfusion_events te ON p.hadm_id = te.hadm_id
LEFT JOIN survival_data sd ON p.hadm_id = sd.hadm_id
LEFT JOIN icu_los i ON p.hadm_id = i.hadm_id
ORDER BY p.subject_id;