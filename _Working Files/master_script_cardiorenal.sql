-- ------------------------------------------------------------------
-- TITLE: MASTER VASCULAR CARDIORENAL PIPELINE (WVS EDITION)
-- DESCRIPTION: End-to-end execution. Includes RCRI variables (Insulin),
--              Ejection Fraction, Cardiac Meds, AUC Hemodynamics, 
--              and a ruthlessly pruned final raw table.
--              *BUILT IN AN ISOLATED CARDIORENAL SCHEMA*
-- ------------------------------------------------------------------

-- 1. SCHEMA SETUP (THE ISOLATION WARD)
CREATE SCHEMA IF NOT EXISTS mimiciv_icu_vascular_cardiorenal;
SET search_path TO mimiciv_icu_vascular_cardiorenal, public;

-- ------------------------------------------------------------------
-- TITLE: CREATE_PATIENTS_TABLE_FINAL_CLEAN
-- DESCRIPTION: Generates the Master Cohort (N ~ 1,000).
--              FILTERS: 1. Vascular Procedure
--                       2. Valid ICU Stay
--                       3. NO ESRD (Dialysis) History
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS Patients;

CREATE TABLE Patients AS
WITH vascular_scans AS (
    -- 1. IDENTIFY TARGET PROCEDURES
    SELECT 
        subject_id,
        hadm_id,
        icd_code,
        icd_version,
        CASE
            -- === GROUP A: OPEN REVASCULARIZATION ===
            WHEN icd_version = 10 AND (icd_code LIKE '04B0%' OR icd_code LIKE '04R0%') THEN 'OPEN_AAA'
            WHEN icd_version = 9  AND (icd_code = '3844') THEN 'OPEN_AAA'
            WHEN icd_version = 10 AND icd_code LIKE '041%' AND SUBSTRING(icd_code, 4, 1) NOT IN ('1','2','3','4','5','6','7','8') THEN 'OPEN_LE_BYPASS'
            WHEN icd_version = 9  AND (icd_code LIKE '3925' OR icd_code LIKE '3929') THEN 'OPEN_LE_BYPASS'
            WHEN icd_version = 10 AND icd_code LIKE '03C%' AND SUBSTRING(icd_code, 4, 1) IN ('K','L','M','N') THEN 'OPEN_CEA'
            WHEN icd_version = 9  AND (icd_code = '3812') THEN 'OPEN_CEA'
            
            -- === GROUP B: ENDOVASCULAR ===
            WHEN icd_version = 10 AND icd_code LIKE '04U0%' THEN 'ENDO_EVAR'
            WHEN icd_version = 9  AND (icd_code = '3971') THEN 'ENDO_EVAR'
            WHEN icd_version = 10 AND (icd_code LIKE '047%' OR icd_code LIKE '04V%') AND SUBSTRING(icd_code, 4, 1) NOT IN ('1','2','3','4','5','6','7','8') THEN 'ENDO_PVI'
            WHEN icd_version = 9  AND (icd_code = '3990' OR icd_code = '3950') THEN 'ENDO_PVI'
            WHEN icd_version = 10 AND icd_code LIKE '037%' AND SUBSTRING(icd_code, 4, 1) IN ('K','L','M','N') THEN 'ENDO_CAS'
            WHEN icd_version = 9  AND (icd_code = '0061' OR icd_code = '0063') THEN 'ENDO_CAS'
            ELSE NULL
        END AS vascular_type
    FROM mimiciv_hosp.procedures_icd
),

exclusions AS (
    -- 2. EXCLUDE CARDIAC / THORACIC
    SELECT DISTINCT hadm_id FROM mimiciv_hosp.procedures_icd
    WHERE (icd_version = 10 AND (icd_code LIKE '021%' OR icd_code LIKE '02R%')) OR
          (icd_version = 9  AND (icd_code LIKE '361%' OR icd_code LIKE '352%')) OR
          (icd_version = 10 AND icd_code LIKE '04V0%') OR 
          (icd_version = 10 AND icd_code LIKE '031%')
),

valid_icu_stays AS (
    -- 3. THE ICU GATEKEEPER
    SELECT DISTINCT hadm_id FROM mimiciv_icu.icustays
),

cohort_staging AS (
    -- 4. MERGE & FILTER (ICU Only)
    SELECT 
        v.subject_id,
        v.hadm_id,
        MAX(CASE WHEN v.vascular_type LIKE 'OPEN%' THEN 1 ELSE 0 END) as has_open,
        MAX(CASE WHEN v.vascular_type LIKE 'ENDO%' THEN 1 ELSE 0 END) as has_endo
    FROM vascular_scans v
    JOIN valid_icu_stays icu ON v.hadm_id = icu.hadm_id -- INNER JOIN DROPS NON-ICU
    WHERE v.vascular_type IS NOT NULL
      AND v.hadm_id NOT IN (SELECT hadm_id FROM exclusions)
    GROUP BY v.subject_id, v.hadm_id
),

ranked_baselines AS (
    -- 5. FIND BASELINE CREATININE
    SELECT 
        c.hadm_id,
        c.subject_id,
        a.admittime,
        le.valuenum as lab_value,
        le.charttime,
        
        CASE 
            WHEN le.charttime::DATE >= (a.admittime::DATE - 7) AND le.charttime::DATE < a.admittime::DATE THEN 1
            WHEN le.charttime::DATE = a.admittime::DATE THEN 2
            WHEN le.charttime::DATE >= (a.admittime::DATE - 90) AND le.charttime::DATE <= (a.admittime::DATE - 8) THEN 3
            ELSE 4
        END as scientific_priority
        
    FROM cohort_staging c
    JOIN mimiciv_hosp.admissions a ON c.hadm_id = a.hadm_id
    JOIN mimiciv_hosp.labevents le 
        ON c.subject_id = le.subject_id 
        AND le.itemid = 50912 -- Creatinine
        AND le.valuenum IS NOT NULL
        AND le.charttime >= (a.admittime - INTERVAL '90 days')
        AND le.charttime <= a.admittime
),

best_baseline AS (
    -- 6. SELECT SINGLE BEST BASELINE
    SELECT 
        hadm_id,
        (ARRAY_AGG(lab_value ORDER BY scientific_priority ASC, charttime DESC))[1] as baseline_creatinine,
        MIN(scientific_priority) as selected_priority
    FROM ranked_baselines
    WHERE scientific_priority <= 3
    GROUP BY hadm_id
),

comorbidities AS (
    -- 7. GENERATE COMORBIDITIES (Including ESRD check)
    SELECT 
        hadm_id,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'I10%' OR icd_code LIKE 'I11%')) OR (icd_version=9 AND icd_code LIKE '401%') THEN 1 ELSE 0 END) as hx_hypertension,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E08%') OR (icd_version=9 AND icd_code LIKE '250%') THEN 1 ELSE 0 END) as hx_diabetes,
        MAX(CASE WHEN (icd_version=10 AND icd_code = 'F172') OR (icd_version=9 AND icd_code = '3051') THEN 1 ELSE 0 END) as hx_smoking,
        -- The Critical Flag: ESRD
        MAX(CASE WHEN (icd_version=10 AND icd_code = 'N186') OR (icd_version=9 AND icd_code = '5856') THEN 1 ELSE 0 END) as hx_esrd
    FROM mimiciv_hosp.diagnoses_icd
    WHERE hadm_id IN (SELECT hadm_id FROM cohort_staging)
    GROUP BY hadm_id
),

admission_labs AS (
    -- 8. ADMISSION LABS (First 24h)
    SELECT 
        l.hadm_id,
        MIN(CASE WHEN itemid = 50813 THEN valuenum END) as admit_lactate,
        MIN(CASE WHEN itemid = 50862 THEN valuenum END) as admit_albumin,
        MIN(CASE WHEN itemid = 51301 THEN valuenum END) as admit_wbc,
        MIN(CASE WHEN itemid = 50931 THEN valuenum END) as admit_glucose,
        MIN(CASE WHEN itemid = 51222 THEN valuenum END) as admit_hemoglobin
    FROM mimiciv_hosp.labevents l
    JOIN cohort_staging c ON l.hadm_id = c.hadm_id
    JOIN mimiciv_hosp.admissions a ON c.hadm_id = a.hadm_id
    WHERE l.charttime >= a.admittime AND l.charttime <= (a.admittime + INTERVAL '24 hours')
    GROUP BY l.hadm_id
)

-- 9. FINAL ASSEMBLY (With ESRD Exclusion)
SELECT 
    c.subject_id,
    c.hadm_id,
    p.anchor_age as age,
    p.gender,
    a.race,
    a.insurance,
    a.marital_status,
    a.admittime,
    a.dischtime,
    CASE 
        WHEN c.has_open = 1 THEN 'OPEN'
        WHEN c.has_endo = 1 THEN 'ENDO'
        ELSE 'UNKNOWN' 
    END as procedure_group,
    bb.baseline_creatinine,
    CASE 
        WHEN bb.selected_priority = 1 THEN 1 
        WHEN bb.selected_priority = 3 THEN 2 
        WHEN bb.selected_priority = 2 THEN 3 
    END as baseline_class_id,
    COALESCE(cm.hx_hypertension, 0) as hx_hypertension,
    COALESCE(cm.hx_diabetes, 0) as hx_diabetes,
    COALESCE(cm.hx_smoking, 0) as hx_smoking,
    COALESCE(cm.hx_esrd, 0) as hx_esrd,
    al.admit_lactate,
    al.admit_albumin,
    al.admit_wbc,
    al.admit_glucose,
    al.admit_hemoglobin

FROM cohort_staging c
JOIN mimiciv_hosp.admissions a ON c.hadm_id = a.hadm_id
JOIN mimiciv_hosp.patients p ON c.subject_id = p.subject_id
JOIN best_baseline bb ON c.hadm_id = bb.hadm_id
LEFT JOIN comorbidities cm ON c.hadm_id = cm.hadm_id
LEFT JOIN admission_labs al ON c.hadm_id = al.hadm_id

-- **THE GATEKEEPER**: Drop ESRD Patients here
WHERE COALESCE(cm.hx_esrd, 0) = 0

ORDER BY c.subject_id;

-- ------------------------------------------------------------------
-- 2. INDEPENDENT SUMMARY TABLES 
-- ------------------------------------------------------------------

-- 2A. COMPLEX AORTIC SUMMARY
DROP TABLE IF EXISTS complex_aortic_summary;
CREATE TABLE complex_aortic_summary AS
WITH icd_search AS (
    SELECT hadm_id, 1 as icd_flag
    FROM mimiciv_hosp.diagnoses_icd
    WHERE 
       icd_code LIKE '4416%' OR icd_code LIKE '4417%' OR icd_code LIKE 'I7150%' OR icd_code LIKE 'I7160%'
       OR icd_code LIKE 'I7131%' OR icd_code LIKE 'I7141%' OR icd_code LIKE 'I7132%' OR icd_code LIKE 'I7142%'
       OR icd_code LIKE 'I7151%' OR icd_code LIKE 'I7161%' OR icd_code LIKE 'I7152%' OR icd_code LIKE 'I7162%'
    GROUP BY hadm_id
),
note_search AS (
    SELECT p.hadm_id,
        CASE 
            WHEN n.text ILIKE '%suprarenal clamp%' THEN 1
            WHEN n.text ILIKE '%supra-renal clamp%' THEN 1
            WHEN n.text ILIKE '%supraceliac%' THEN 1
            WHEN n.text ILIKE '%supra-celiac%' THEN 1
            WHEN n.text ILIKE '%juxtarenal%' THEN 1
            WHEN n.text ILIKE '%juxta-renal%' THEN 1
            WHEN n.text ILIKE '%thoracoabdominal%' THEN 1
            WHEN n.text ILIKE '%pararenal%' THEN 1
            ELSE 0
        END as nlp_flag
    FROM Patients p -- Pulling core cohort from your original setup
    JOIN mimiciv_note.discharge n ON p.hadm_id = n.hadm_id
),
aggregated_nlp AS (
    SELECT hadm_id, MAX(nlp_flag) as nlp_flag FROM note_search GROUP BY hadm_id
)
SELECT p.subject_id, p.hadm_id,
    CASE WHEN COALESCE(i.icd_flag, 0) = 1 OR COALESCE(n.nlp_flag, 0) = 1 THEN 1 ELSE 0 END as complex_aortic
FROM Patients p
LEFT JOIN icd_search i ON p.hadm_id = i.hadm_id
LEFT JOIN aggregated_nlp n ON p.hadm_id = n.hadm_id;

-- 2B. AKI TIME WINDOWS SUMMARY 
DROP TABLE IF EXISTS aki_time_windows_summary;
CREATE TABLE aki_time_windows_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
),
admit_baseline AS (
    SELECT a.hadm_id, MIN(le.valuenum) as admit_creatinine
    FROM icu_anchor a JOIN mimiciv_hosp.labevents le ON a.hadm_id = le.hadm_id
    WHERE le.itemid = 50912 AND le.charttime >= (a.icu_start_time - INTERVAL '7 days') AND le.charttime <= (a.icu_start_time + INTERVAL '24 hours')
    GROUP BY a.hadm_id
),
daily_cr AS (
    SELECT a.hadm_id, b.admit_creatinine, CEIL(EXTRACT(EPOCH FROM (le.charttime - (a.icu_start_time - INTERVAL '24 hours')))/86400.0) as icu_day, MAX(le.valuenum) as max_cr_day
    FROM icu_anchor a JOIN admit_baseline b ON a.hadm_id = b.hadm_id JOIN mimiciv_hosp.labevents le ON a.hadm_id = le.hadm_id
    WHERE le.itemid = 50912 AND le.charttime >= (a.icu_start_time - INTERVAL '24 hours') AND le.charttime <= (a.icu_start_time + INTERVAL '7 days')
    GROUP BY a.hadm_id, b.admit_creatinine, CEIL(EXTRACT(EPOCH FROM (le.charttime - (a.icu_start_time - INTERVAL '24 hours')))/86400.0)
),
aki_days AS (
    SELECT hadm_id, icu_day, max_cr_day, admit_creatinine,
        CASE WHEN max_cr_day >= (admit_creatinine * 1.5) OR max_cr_day >= (admit_creatinine + 0.3) THEN 1 ELSE 0 END as aki_met,
        CASE WHEN max_cr_day >= (admit_creatinine * 3.0) OR max_cr_day >= 4.0 THEN 3
             WHEN max_cr_day >= (admit_creatinine * 2.0) THEN 2
             WHEN max_cr_day >= (admit_creatinine * 1.5) OR max_cr_day >= (admit_creatinine + 0.3) THEN 1 ELSE 0 END as daily_aki_stage
    FROM daily_cr
)
SELECT hadm_id,
    MAX(CASE WHEN icu_day = 1 THEN aki_met ELSE 0 END) as aki_24h_flag,
    MAX(CASE WHEN icu_day <= 3 THEN aki_met ELSE 0 END) as aki_72h_flag,
    MAX(CASE WHEN icu_day <= 7 THEN aki_met ELSE 0 END) as aki_7day_flag,
    MAX(CASE WHEN icu_day <= 7 THEN daily_aki_stage ELSE 0 END) as max_aki_stage_7day
FROM aki_days GROUP BY hadm_id;

-- 2C. HEMODYNAMIC BURDEN & MAP TWA SUMMARY (The AUC Calculation)
DROP TABLE IF EXISTS map_twa_summary;
CREATE TABLE map_twa_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
),
clean_map AS (
    SELECT ce.hadm_id, ce.charttime, ce.valuenum as map_val FROM mimiciv_icu.chartevents ce JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid IN (220052, 220181, 225312) AND ce.charttime >= a.icu_start_time AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours') AND ce.valuenum BETWEEN 40 AND 180
),
clean_hr AS (
    SELECT ce.hadm_id, ce.charttime, ce.valuenum as hr_val FROM mimiciv_icu.chartevents ce JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid = 220045 AND ce.charttime >= a.icu_start_time AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours') AND ce.valuenum BETWEEN 30 AND 220
),
map_intervals AS (
    SELECT hadm_id, map_val, charttime, EXTRACT(EPOCH FROM (LEAD(charttime) OVER (PARTITION BY hadm_id ORDER BY charttime) - charttime)) / 3600.0 as dur FROM clean_map
),
hr_intervals AS (
    SELECT hadm_id, hr_val, charttime, EXTRACT(EPOCH FROM (LEAD(charttime) OVER (PARTITION BY hadm_id ORDER BY charttime) - charttime)) / 3600.0 as dur FROM clean_hr
),
map_agg AS (
    SELECT hadm_id, ROUND(CAST(SUM(map_val * dur) / NULLIF(SUM(dur), 0) AS NUMERIC), 1) as map_twa_24h, SUM(CASE WHEN map_val < 65 THEN dur ELSE 0 END) as hours_map_below_65
    FROM map_intervals WHERE dur IS NOT NULL AND dur < 4 GROUP BY hadm_id
),
hr_agg AS (
    SELECT hadm_id, SUM(CASE WHEN hr_val > 90 THEN dur ELSE 0 END) as hours_hr_above_90 FROM hr_intervals WHERE dur IS NOT NULL AND dur < 4 GROUP BY hadm_id
)
SELECT m.hadm_id, m.map_twa_24h, ROUND(CAST(m.hours_map_below_65 AS NUMERIC), 2) as hours_map_below_65, ROUND(CAST(h.hours_hr_above_90 AS NUMERIC), 2) as hours_hr_above_90
FROM map_agg m LEFT JOIN hr_agg h ON m.hadm_id = h.hadm_id;

-- 2D. HEMO PRESSOR SUMMARY
DROP TABLE IF EXISTS hemo_pressor_summary;
CREATE TABLE hemo_pressor_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
),
clean_hr AS (
    SELECT ce.hadm_id, ce.valuenum as hr_val, ce.charttime FROM mimiciv_icu.chartevents ce JOIN icu_anchor a ON ce.hadm_id = a.hadm_id
    WHERE ce.itemid = 220045 AND ce.charttime >= a.icu_start_time AND ce.charttime <= (a.icu_start_time + INTERVAL '24 hours')
),
hr_agg AS (
    SELECT DISTINCT ON (hadm_id) hadm_id, hr_val as hr_admit FROM clean_hr ORDER BY hadm_id, charttime ASC
),
pressor_agg AS (
    SELECT ie.hadm_id, SUM(EXTRACT(EPOCH FROM (ie.endtime - ie.starttime))/3600.0) as pressor_hours, MAX(CASE WHEN ie.rate > 0 THEN ie.rate WHEN ie.amount > 0 THEN 0.01 ELSE 0 END) as max_pressor_dose
    FROM mimiciv_icu.inputevents ie JOIN icu_anchor a ON ie.hadm_id = a.hadm_id
    WHERE ie.starttime >= a.icu_start_time AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours') AND ie.itemid IN (221906, 221289, 222315, 221749, 221662) GROUP BY ie.hadm_id
)
SELECT p.hadm_id, COALESCE(h.hr_admit, 0) as hr_admit, CASE WHEN pr.pressor_hours > 0 THEN 1 ELSE 0 END as vasopressor_flag, ROUND(CAST(COALESCE(pr.pressor_hours, 0) AS NUMERIC), 1) as pressor_hours, COALESCE(pr.max_pressor_dose, 0) as max_pressor_dose
FROM Patients p LEFT JOIN hr_agg h ON p.hadm_id = h.hadm_id LEFT JOIN pressor_agg pr ON p.hadm_id = pr.hadm_id;

-- 2E. RENAL FLUID SUMMARY
DROP TABLE IF EXISTS renal_fluid_summary;
CREATE TABLE renal_fluid_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
),
uo_24h AS (
    SELECT oe.hadm_id, SUM(oe.value) as urine_output_24h FROM mimiciv_icu.outputevents oe JOIN icu_anchor a ON oe.hadm_id = a.hadm_id
    WHERE oe.charttime >= a.icu_start_time AND oe.charttime <= (a.icu_start_time + INTERVAL '24 hours') GROUP BY oe.hadm_id
),
fluids_in AS (
    SELECT ie.hadm_id, SUM(amount) as total_fluid_intake_24h FROM mimiciv_icu.inputevents ie JOIN icu_anchor a ON ie.hadm_id = a.hadm_id
    WHERE ie.starttime >= a.icu_start_time AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours') AND amount > 0 GROUP BY ie.hadm_id
)
SELECT p.hadm_id, COALESCE(uo.urine_output_24h, 0) as urine_output_24h, COALESCE(fi.total_fluid_intake_24h, 0) as total_fluid_intake_24h, (COALESCE(fi.total_fluid_intake_24h, 0) - COALESCE(uo.urine_output_24h, 0)) as fluid_balance_24h
FROM Patients p LEFT JOIN uo_24h uo ON p.hadm_id = uo.hadm_id LEFT JOIN fluids_in fi ON p.hadm_id = fi.hadm_id;

-- 2F. PRUNED LAB VITAL DRAGNET
DROP TABLE IF EXISTS lab_vital_dragnet;
CREATE TABLE lab_vital_dragnet AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
)
SELECT le.hadm_id,
    ROUND(CAST(AVG(CASE WHEN itemid = 51006 THEN valuenum END) AS NUMERIC), 1) as bun_mean,
    ROUND(CAST(AVG(CASE WHEN itemid = 51301 THEN valuenum END) AS NUMERIC), 1) as wbc_mean,
    ROUND(CAST(AVG(CASE WHEN itemid = 51265 THEN valuenum END) AS NUMERIC), 0) as platelets_mean,
    MAX(CASE WHEN itemid = 50813 THEN valuenum END) as lactate_max
FROM mimiciv_hosp.labevents le JOIN icu_anchor a ON le.hadm_id = a.hadm_id
WHERE le.charttime >= (a.icu_start_time - INTERVAL '6 hours') AND le.charttime <= (a.icu_start_time + INTERVAL '24 hours')
GROUP BY le.hadm_id;

-- 2G. SAFETY SURVIVAL SUMMARY
DROP TABLE IF EXISTS safety_survival_summary;
CREATE TABLE safety_survival_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
),
safety_labs AS (
    SELECT le.hadm_id,
        MAX(CASE WHEN le.itemid IN (51002, 51003, 50963) AND le.charttime <= (a.icu_start_time + INTERVAL '72 hours') THEN le.valuenum END) as raw_trop_72h,
        MAX(CASE WHEN le.itemid IN (51002, 51003, 50963) AND le.charttime <= (a.icu_start_time + INTERVAL '7 days') THEN le.valuenum END) as raw_trop_7day,
        MIN(CASE WHEN le.itemid = 51222 AND le.charttime <= (a.icu_start_time + INTERVAL '24 hours') THEN le.valuenum END) as min_hgb_24h
    FROM mimiciv_hosp.labevents le JOIN icu_anchor a ON le.hadm_id = a.hadm_id
    WHERE le.charttime >= (a.icu_start_time - INTERVAL '6 hours') AND le.charttime <= (a.icu_start_time + INTERVAL '7 days') GROUP BY le.hadm_id
),
transfusion_events AS (
    SELECT ie.hadm_id, MAX(CASE WHEN ie.starttime <= (a.icu_start_time + INTERVAL '24 hours') THEN 1 ELSE 0 END) as transfusion_24h
    FROM mimiciv_icu.inputevents ie JOIN icu_anchor a ON ie.hadm_id = a.hadm_id
    WHERE ie.itemid = 225168 AND ie.amount > 0 AND ie.starttime >= (a.icu_start_time - INTERVAL '6 hours') AND ie.starttime <= (a.icu_start_time + INTERVAL '24 hours') GROUP BY ie.hadm_id
),
survival_data AS (
    SELECT a.hadm_id, a.hospital_expire_flag, pat.dod as date_of_death,
        CASE WHEN a.hospital_expire_flag = 1 THEN EXTRACT(EPOCH FROM (COALESCE(a.deathtime, pat.dod::timestamp) - a.admittime))/86400.0 ELSE NULL END as time_to_death_days
    FROM mimiciv_hosp.admissions a JOIN mimiciv_hosp.patients pat ON a.subject_id = pat.subject_id JOIN Patients p ON a.hadm_id = p.hadm_id
)
SELECT p.hadm_id,
    CASE WHEN sl.raw_trop_72h > 0.04 THEN 1 ELSE 0 END as myocardial_injury_72h,
    CASE WHEN sl.raw_trop_7day > 0.04 THEN 1 ELSE 0 END as myocardial_injury_7day,
    sl.min_hgb_24h, COALESCE(te.transfusion_24h, 0) as transfusion_24h,
    sd.hospital_expire_flag, sd.date_of_death, ROUND(CAST(sd.time_to_death_days AS NUMERIC), 2) as time_to_death_days
FROM Patients p LEFT JOIN safety_labs sl ON p.hadm_id = sl.hadm_id LEFT JOIN transfusion_events te ON p.hadm_id = te.hadm_id LEFT JOIN survival_data sd ON p.hadm_id = sd.hadm_id;

-- 2H. COMORBIDITY SCORES
DROP TABLE IF EXISTS comorbidity_summary;
CREATE TABLE comorbidity_summary AS
WITH raw_flags AS (
    SELECT hadm_id,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I50%') OR (icd_version=9 AND icd_code LIKE '428%') THEN 1 ELSE 0 END) as chf,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I70%') OR (icd_version=9 AND icd_code LIKE '440%') THEN 1 ELSE 0 END) as pvd,
        MAX(CASE WHEN (icd_version=10 AND icd_code BETWEEN 'I11' AND 'I15') OR (icd_version=9 AND icd_code BETWEEN '402' AND '405') THEN 1 ELSE 0 END) as htn_comp,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'J4%') OR (icd_version=9 AND icd_code BETWEEN '490' AND '496') THEN 1 ELSE 0 END) as copd,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'E10%' AND icd_code NOT LIKE '%9')) OR (icd_version=9 AND (icd_code LIKE '2504%' OR icd_code LIKE '2505%' OR icd_code LIKE '2506%' OR icd_code LIKE '2507%')) THEN 1 ELSE 0 END) as dm_comp,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'N18%') OR (icd_version=9 AND icd_code LIKE '585%') THEN 1 ELSE 0 END) as renal,
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'I85%' OR icd_code LIKE 'K72%')) OR (icd_version=9 AND (icd_code LIKE '4560%' OR icd_code LIKE '4561%' OR icd_code LIKE '5722%')) THEN 1 ELSE 0 END) as liver_sev,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E66%') OR (icd_version=9 AND icd_code LIKE '2780%') THEN 1 ELSE 0 END) as obesity,
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'D6%') OR (icd_version=9 AND icd_code LIKE '286%') THEN 1 ELSE 0 END) as coag
    FROM mimiciv_hosp.diagnoses_icd GROUP BY hadm_id
)
SELECT p.hadm_id, COALESCE(dc.charlson_comorbidity_index, 0) as charlson_score,
    rf.chf, rf.pvd, rf.htn_comp, rf.copd, rf.dm_comp, rf.renal, rf.liver_sev, rf.obesity, rf.coag
FROM Patients p LEFT JOIN raw_flags rf ON p.hadm_id = rf.hadm_id LEFT JOIN mimiciv_derived.charlson dc ON p.hadm_id = dc.hadm_id;

-- 2I. CARDIAC MEDICATIONS SUMMARY (WITH INSULIN)
DROP TABLE IF EXISTS cardiac_meds_summary;
CREATE TABLE cardiac_meds_summary AS
SELECT 
    p.hadm_id,
    MAX(CASE WHEN pr.drug ILIKE '%metoprolol%' OR pr.drug ILIKE '%carvedilol%' OR pr.drug ILIKE '%atenolol%' OR pr.drug ILIKE '%labetalol%' THEN 1 ELSE 0 END) as beta_blocker,
    MAX(CASE WHEN pr.drug ILIKE '%lisinopril%' OR pr.drug ILIKE '%losartan%' OR pr.drug ILIKE '%valsartan%' OR pr.drug ILIKE '%enalapril%' THEN 1 ELSE 0 END) as ace_arb,
    MAX(CASE WHEN pr.drug ILIKE '%atorvastatin%' OR pr.drug ILIKE '%rosuvastatin%' OR pr.drug ILIKE '%simvastatin%' OR pr.drug ILIKE '%pravastatin%' THEN 1 ELSE 0 END) as statin,
    MAX(CASE WHEN pr.drug ILIKE '%aspirin%' OR pr.drug ILIKE '%clopidogrel%' OR pr.drug ILIKE '%plavix%' OR pr.drug ILIKE '%ticagrelor%' THEN 1 ELSE 0 END) as antiplatelet,
    MAX(CASE WHEN pr.drug ILIKE '%insulin%' THEN 1 ELSE 0 END) as insulin_flag
FROM Patients p
LEFT JOIN mimiciv_hosp.prescriptions pr ON p.hadm_id = pr.hadm_id
GROUP BY p.hadm_id;

-- 2J. ECHO & EJECTION FRACTION SUMMARY
DROP TABLE IF EXISTS echo_summary;
CREATE TABLE echo_summary AS
SELECT p.hadm_id, MAX(CAST(SUBSTRING(n.text FROM '(?i)ejection fraction.*?([0-9]{2})') AS NUMERIC)) as ejection_fraction
FROM Patients p LEFT JOIN mimiciv_note.discharge n ON p.hadm_id = n.hadm_id GROUP BY p.hadm_id;

-- 2K. RRT (DIALYSIS) SUMMARY
DROP TABLE IF EXISTS rrt_summary;
CREATE TABLE rrt_summary AS
WITH icu_anchor AS (
    SELECT p.hadm_id, MIN(ie.intime) as icu_start_time FROM Patients p JOIN mimiciv_icu.icustays ie ON p.hadm_id = ie.hadm_id GROUP BY p.hadm_id
)
SELECT pe.hadm_id, MAX(CASE WHEN pe.itemid IN (225802, 225803, 225436, 225809) THEN 1 ELSE 0 END) as rrt_flag
FROM mimiciv_icu.procedureevents pe JOIN icu_anchor a ON pe.hadm_id = a.hadm_id WHERE pe.starttime >= a.icu_start_time GROUP BY pe.hadm_id;

-- ------------------------------------------------------------------
-- 3. THE FINAL PRUNED MASTER TABLE
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS master_vascular_cardiorenal_raw;
CREATE TABLE master_vascular_cardiorenal_raw AS
SELECT 
    -- 1. Demographics & Baseline
    p.subject_id, p.hadm_id, p.age, p.gender, p.race, p.procedure_group,
    p.baseline_creatinine, p.baseline_class_id,
    
    -- 2. Hemodynamic & Tachycardic Burden (AUC)
    twa.map_twa_24h, twa.hours_map_below_65, twa.hours_hr_above_90, h.hr_admit,
    
    -- 3. Resuscitation (Pressors & Fluids)
    h.vasopressor_flag, h.pressor_hours, h.max_pressor_dose,
    r.urine_output_24h, r.total_fluid_intake_24h, r.fluid_balance_24h,
    s.transfusion_24h,
    
    -- 4. Cardiovascular Protection (Meds & Echo)
    COALESCE(cm.beta_blocker, 0) as beta_blocker,
    COALESCE(cm.ace_arb, 0) as ace_arb,
    COALESCE(cm.statin, 0) as statin,
    COALESCE(cm.antiplatelet, 0) as antiplatelet,
    COALESCE(cm.insulin_flag, 0) as insulin_flag,
    es.ejection_fraction,
    
   -- 5. Curated Comorbidities
    c.charlson_score, c.chf as hx_chf, c.renal as hx_ckd, c.pvd as hx_pvd,
    c.copd as hx_copd, c.dm_comp as hx_diabetes_comp, 
    c.htn_comp as hx_hypertension_comp, c.liver_sev, c.obesity, c.coag,
    p.hx_hypertension, p.hx_diabetes, p.hx_smoking, p.hx_esrd,

-- 6. Critical Labs
    l.lactate_max, l.bun_mean, l.wbc_mean, l.platelets_mean, s.min_hgb_24h,
    p.admit_lactate, p.admit_albumin, p.admit_wbc, p.admit_glucose, p.admit_hemoglobin, 

    -- 7. The Double Hit Targets & Survival
    COALESCE(atw.aki_24h_flag, 0) as aki_24h_flag,
    COALESCE(atw.aki_7day_flag, 0) as aki_7day_flag,
    COALESCE(atw.max_aki_stage_7day, 0) as max_aki_stage_7day,
    s.myocardial_injury_72h, s.myocardial_injury_7day,
    COALESCE(rrt.rrt_flag, 0) as rrt_flag,
    s.hospital_expire_flag, s.date_of_death, s.time_to_death_days

FROM Patients p
LEFT JOIN hemo_pressor_summary h ON p.hadm_id = h.hadm_id
LEFT JOIN renal_fluid_summary r ON p.hadm_id = r.hadm_id
LEFT JOIN comorbidity_summary c ON p.hadm_id = c.hadm_id
LEFT JOIN lab_vital_dragnet l ON p.hadm_id = l.hadm_id
LEFT JOIN safety_survival_summary s ON p.hadm_id = s.hadm_id
LEFT JOIN map_twa_summary twa ON p.hadm_id = twa.hadm_id
LEFT JOIN cardiac_meds_summary cm ON p.hadm_id = cm.hadm_id
LEFT JOIN echo_summary es ON p.hadm_id = es.hadm_id
LEFT JOIN rrt_summary rrt ON p.hadm_id = rrt.hadm_id
LEFT JOIN aki_time_windows_summary atw ON p.hadm_id = atw.hadm_id;