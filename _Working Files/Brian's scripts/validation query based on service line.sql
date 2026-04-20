-- ------------------------------------------------------------------
-- TITLE: FULL_VALIDATION_QUERY (Combined)
-- DESCRIPTION: Generates the cohort AND compares it to the Service Line in one shot.
-- ------------------------------------------------------------------

WITH vascular_scans AS (
    -- 1. IDENTIFY POTENTIAL VASCULAR PROCEDURES
    SELECT 
        hadm_id,
        icd_code,
        icd_version,
        CASE
            -- Group A: OPEN
            WHEN icd_version = 10 AND (icd_code LIKE '04B%' OR icd_code LIKE '04R%') THEN 'OPEN_AAA'
            WHEN icd_version = 9  AND (icd_code = '3844') THEN 'OPEN_AAA'
            WHEN icd_version = 10 AND icd_code LIKE '041%' THEN 'OPEN_LE_BYPASS'
            WHEN icd_version = 9  AND (icd_code LIKE '3925' OR icd_code LIKE '3929') THEN 'OPEN_LE_BYPASS'
            WHEN icd_version = 10 AND (icd_code LIKE '03CK%' OR icd_code LIKE '03CL%') THEN 'OPEN_CEA'
            WHEN icd_version = 9  AND icd_code = '3812' THEN 'OPEN_CEA'
            
            -- Group B: ENDO
            WHEN icd_version = 10 AND (icd_code LIKE '04U0%' OR icd_code LIKE '04V0%') THEN 'ENDO_EVAR'
            WHEN icd_version = 9  AND icd_code = '3971' THEN 'ENDO_EVAR'
            WHEN icd_version = 10 AND (icd_code LIKE '047%' OR icd_code LIKE '04V%') THEN 'ENDO_PVI'
            WHEN icd_version = 9  AND (icd_code = '3990' OR icd_code = '3950') THEN 'ENDO_PVI'
            WHEN icd_version = 10 AND icd_code LIKE '037%' THEN 'ENDO_CAS'
            WHEN icd_version = 9  AND (icd_code = '0061' OR icd_code = '0063') THEN 'ENDO_CAS'
            
            ELSE NULL
        END AS vascular_type
    FROM mimiciv_hosp.procedures_icd
),

exclusions AS (
    -- 2. IDENTIFY EXCLUSIONS (Cardiac/Thoracic/etc)
    SELECT DISTINCT hadm_id
    FROM mimiciv_hosp.procedures_icd
    WHERE 
        (icd_version = 10 AND (icd_code LIKE '021%' OR icd_code LIKE '02R%')) OR
        (icd_version = 9  AND (icd_code LIKE '361%' OR icd_code LIKE '352%')) OR
        (icd_version = 10 AND icd_code LIKE '04V0%') OR 
        (icd_version = 10 AND icd_code LIKE '031%')
),

icd_cohort AS (
    -- 3. FINALIZE THE ICD COHORT (The 8193 patients)
    SELECT DISTINCT hadm_id
    FROM vascular_scans v
    WHERE v.vascular_type IS NOT NULL
      AND v.hadm_id NOT IN (SELECT hadm_id FROM exclusions)
),

service_cohort AS (
    -- 4. IDENTIFY VASCULAR SERVICE PATIENTS
    SELECT DISTINCT hadm_id
    FROM mimiciv_hosp.services
    WHERE curr_service = 'VSURG'
)

-- 5. PERFORM THE VENN DIAGRAM COMPARISON
SELECT 
    'Both (Gold Standard)' as category,
    COUNT(hadm_id) as patient_count
FROM icd_cohort
WHERE hadm_id IN (SELECT hadm_id FROM service_cohort)

UNION ALL

SELECT 
    'ICD Only (Off-Service Procedures)',
    COUNT(hadm_id)
FROM icd_cohort
WHERE hadm_id NOT IN (SELECT hadm_id FROM service_cohort)

UNION ALL

SELECT 
    'Service Only (Non-Operative/Missed Coding)',
    COUNT(hadm_id)
FROM service_cohort
WHERE hadm_id NOT IN (SELECT hadm_id FROM icd_cohort);