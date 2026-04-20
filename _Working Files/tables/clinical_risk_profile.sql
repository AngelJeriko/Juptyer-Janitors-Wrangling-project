-- ------------------------------------------------------------------
-- TITLE: CREATE_CLINICAL_RISK_PROFILE_MANUAL
-- DESCRIPTION: Generates Table 1 Risk Factors directly from raw ICD codes.
--              NO EXTERNAL SCRIPTS OR GITHUB REPOS REQUIRED.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS clinical_risk_profile;

CREATE TABLE clinical_risk_profile AS
WITH comorbidity_flags AS (
    -- 1. SCAN DIAGNOSES FOR KEY VASCULAR RISKS
    SELECT 
        hadm_id,
        
        -- HYPERTENSION
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I1%') 
                   OR (icd_version=9 AND icd_code LIKE '401%') 
            THEN 1 ELSE 0 END) as hx_hypertension,
            
        -- DIABETES
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'E0%') 
                   OR (icd_version=9 AND icd_code LIKE '250%') 
            THEN 1 ELSE 0 END) as hx_diabetes,
            
        -- CHF (Congestive Heart Failure)
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I50%') 
                   OR (icd_version=9 AND icd_code LIKE '428%') 
            THEN 1 ELSE 0 END) as hx_chf,
            
        -- COPD
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'J44%') 
                   OR (icd_version=9 AND (icd_code LIKE '491%' OR icd_code LIKE '492%' OR icd_code LIKE '496%')) 
            THEN 1 ELSE 0 END) as hx_copd,
            
        -- CAD (Coronary Artery Disease)
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'I25%') 
                   OR (icd_version=9 AND icd_code LIKE '414%') 
            THEN 1 ELSE 0 END) as hx_cad,
            
        -- STROKE/TIA
        MAX(CASE WHEN (icd_version=10 AND (icd_code LIKE 'I63%' OR icd_code LIKE 'G45%')) 
                   OR (icd_version=9 AND (icd_code LIKE '433%' OR icd_code LIKE '434%' OR icd_code LIKE '435%')) 
            THEN 1 ELSE 0 END) as hx_stroke,
            
        -- CKD (Chronic Kidney Disease - Stages 1-4)
        -- We already excluded Stage 5/ESRD. This finds the "at risk" kidneys.
        MAX(CASE WHEN (icd_version=10 AND icd_code LIKE 'N18%') 
                   OR (icd_version=9 AND icd_code LIKE '585%') 
            THEN 1 ELSE 0 END) as hx_ckd_baseline

    FROM mimiciv_hosp.diagnoses_icd
    GROUP BY hadm_id
)

-- 2. FINAL MERGE WITH MASTER PATIENT TABLE
SELECT 
    p.subject_id,
    p.hadm_id,
    
    -- Binary Flags (0/1) for Table 1 and PSM Matching
    COALESCE(cf.hx_hypertension, 0) as hx_hypertension,
    COALESCE(cf.hx_diabetes, 0) as hx_diabetes,
    COALESCE(cf.hx_chf, 0) as hx_chf,
    COALESCE(cf.hx_copd, 0) as hx_copd,
    COALESCE(cf.hx_cad, 0) as hx_cad,
    COALESCE(cf.hx_stroke, 0) as hx_stroke,
    COALESCE(cf.hx_ckd_baseline, 0) as hx_ckd_baseline

FROM Patients p
LEFT JOIN comorbidity_flags cf ON p.hadm_id = cf.hadm_id
ORDER BY p.subject_id;