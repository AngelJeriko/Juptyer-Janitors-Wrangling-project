-- ------------------------------------------------------------------
-- TITLE: PROJ_VASCULAR_COHORT (CORRECTED SCHEMAS)
-- ------------------------------------------------------------------

WITH vascular_scans AS (
    -- Step 1: Scan procedures_icd for ANY matching code
    SELECT 
        subject_id,
        hadm_id,
        icd_code,
        icd_version,
        CASE
            -- GROUP A: OPEN REVASCULARIZATION
            WHEN icd_version = 10 AND (icd_code LIKE '04B%' OR icd_code LIKE '04R%') THEN 'OPEN_AAA'
            WHEN icd_version = 9  AND (icd_code = '3844') THEN 'OPEN_AAA'
            
            WHEN icd_version = 10 AND icd_code LIKE '041%' THEN 'OPEN_LE_BYPASS'
            WHEN icd_version = 9  AND (icd_code LIKE '3925' OR icd_code LIKE '3929') THEN 'OPEN_LE_BYPASS'
            
            WHEN icd_version = 10 AND (icd_code LIKE '03CK%' OR icd_code LIKE '03CL%') THEN 'OPEN_CEA'
            WHEN icd_version = 9  AND icd_code = '3812' THEN 'OPEN_CEA'
            
            -- GROUP B: ENDOVASCULAR
            WHEN icd_version = 10 AND (icd_code LIKE '04U0%' OR icd_code LIKE '04V0%') THEN 'ENDO_EVAR'
            WHEN icd_version = 9  AND icd_code = '3971' THEN 'ENDO_EVAR'
            
            WHEN icd_version = 10 AND (icd_code LIKE '047%' OR icd_code LIKE '04V%') THEN 'ENDO_PVI'
            WHEN icd_version = 9  AND (icd_code = '3990' OR icd_code = '3950') THEN 'ENDO_PVI'
            
            WHEN icd_version = 10 AND icd_code LIKE '037%' THEN 'ENDO_CAS'
            WHEN icd_version = 9  AND (icd_code = '0061' OR icd_code = '0063') THEN 'ENDO_CAS'
            
            ELSE NULL
        END AS vascular_type
    FROM mimiciv_hosp.procedures_icd  -- <--- FIXED SCHEMA
),

exclusions AS (
    -- Step 2: Identify admissions with "Poison Pill" procedures
    SELECT DISTINCT hadm_id
    FROM mimiciv_hosp.procedures_icd -- <--- FIXED SCHEMA
    WHERE 
        (icd_version = 10 AND (icd_code LIKE '021%' OR icd_code LIKE '02R%')) OR
        (icd_version = 9  AND (icd_code LIKE '361%' OR icd_code LIKE '352%')) OR
        (icd_version = 10 AND icd_code LIKE '04V0%') OR 
        (icd_version = 10 AND icd_code LIKE '031%')
),

cohort_staging AS (
    -- Step 3: Aggregate flags per admission
    SELECT 
        v.subject_id,
        v.hadm_id,
        MAX(CASE WHEN v.vascular_type LIKE 'OPEN%' THEN 1 ELSE 0 END) as has_open,
        MAX(CASE WHEN v.vascular_type LIKE 'ENDO%' THEN 1 ELSE 0 END) as has_endo
    FROM vascular_scans v
    WHERE v.vascular_type IS NOT NULL
      AND v.hadm_id NOT IN (SELECT hadm_id FROM exclusions)
    GROUP BY v.subject_id, v.hadm_id
)

-- Step 4: Final Classification
SELECT 
    c.subject_id,
    c.hadm_id,
    a.admittime,
    a.dischtime,
    p.anchor_age,
    p.gender,
    CASE 
        WHEN c.has_open = 1 THEN 'OPEN'
        WHEN c.has_endo = 1 THEN 'ENDO'
        ELSE 'UNKNOWN'
    END as group_type
FROM cohort_staging c
JOIN mimiciv_hosp.admissions a ON c.hadm_id = a.hadm_id -- <--- FIXED SCHEMA
JOIN mimiciv_hosp.patients p ON c.subject_id = p.subject_id -- <--- FIXED SCHEMA
ORDER BY c.subject_id, a.admittime;