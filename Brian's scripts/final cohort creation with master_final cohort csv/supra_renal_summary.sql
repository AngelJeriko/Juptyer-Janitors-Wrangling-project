-- ------------------------------------------------------------------
-- TITLE: EXTRACT_HIGH_RISK_CLAMP_SUMMARY (Final NLP + ICD Version)
-- DESCRIPTION: Identifies high-risk suprarenal cross-clamping using 
--              both ICD billing codes and NLP text mining of Op Notes.
-- ------------------------------------------------------------------

DROP TABLE IF EXISTS suprarenal_clamp_summary;

CREATE TABLE suprarenal_clamp_summary AS
WITH icd_search AS (
    -- NET 1: Catch Complex Aneurysms via Billing Codes
    SELECT hadm_id, 1 as icd_flag
    FROM mimiciv_hosp.diagnoses_icd
    WHERE 
       -- Old Generic TAAA Codes (Pre-2022)
       icd_code LIKE '4416%' OR icd_code LIKE '4417%' OR icd_code LIKE 'I7150%' OR icd_code LIKE 'I7160%'
       -- New Specific ICD-10 Codes (Effective Oct 2022)
       OR icd_code LIKE 'I7131%' -- Pararenal, ruptured
       OR icd_code LIKE 'I7141%' -- Pararenal, without rupture
       OR icd_code LIKE 'I7132%' -- Juxtarenal, ruptured
       OR icd_code LIKE 'I7142%' -- Juxtarenal, without rupture
       OR icd_code LIKE 'I7151%' -- Supraceliac, ruptured
       OR icd_code LIKE 'I7161%' -- Supraceliac, without rupture
       OR icd_code LIKE 'I7152%' -- Paravisceral, ruptured
       OR icd_code LIKE 'I7162%' -- Paravisceral, without rupture
    GROUP BY hadm_id
),

note_search AS (
    -- NET 2: Catch Cases via NLP Text Mining
    SELECT 
        p.hadm_id,
        CASE 
            -- Anatomical Location Keywords
            WHEN n.text ILIKE '%suprarenal clamp%' THEN 1
            WHEN n.text ILIKE '%supra-renal clamp%' THEN 1
            WHEN n.text ILIKE '%supraceliac%' THEN 1
            WHEN n.text ILIKE '%supra-celiac%' THEN 1
            WHEN n.text ILIKE '%above the renal%' THEN 1
            WHEN n.text ILIKE '%clamp above the renal%' THEN 1
            WHEN n.text ILIKE '%juxtarenal%' THEN 1
            WHEN n.text ILIKE '%juxta-renal%' THEN 1
            WHEN n.text ILIKE '%perivisceral%' THEN 1
            WHEN n.text ILIKE '%paravisceral%' THEN 1
            WHEN n.text ILIKE '%thoracoabdominal%' THEN 1
            WHEN n.text ILIKE '%pararenal%' THEN 1
            
            -- Direct Renal Clamping (Note the leading spaces to avoid "unclamped")
            WHEN n.text ILIKE '% clamped the renal%' THEN 1
            WHEN n.text ILIKE '% clamp on the renal%' THEN 1
            WHEN n.text ILIKE '% clamp on the left renal%' THEN 1
            WHEN n.text ILIKE '% clamp on the right renal%' THEN 1
            ELSE 0
        END as nlp_flag
    FROM Patients p
    JOIN mimiciv_note.discharge n ON p.hadm_id = n.hadm_id
),

aggregated_nlp AS (
    -- Consolidate in case a patient has multiple addendums
    SELECT hadm_id, MAX(nlp_flag) as nlp_flag
    FROM note_search
    GROUP BY hadm_id
)

-- COMBINE NETS: If either flagged it, they get a 1.
SELECT 
    p.subject_id,
    p.hadm_id,
    CASE 
        WHEN COALESCE(i.icd_flag, 0) = 1 OR COALESCE(n.nlp_flag, 0) = 1 THEN 1 
        ELSE 0 
    END as suprarenal_clamp_flag
FROM Patients p
LEFT JOIN icd_search i ON p.hadm_id = i.hadm_id
LEFT JOIN aggregated_nlp n ON p.hadm_id = n.hadm_id
ORDER BY p.subject_id;