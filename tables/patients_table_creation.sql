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