-- ------------------------------------------------------------------
-- TITLE: EXTRACT_RAW_MAP
-- DESCRIPTION: Pulls all MAP readings for the vascular cohort
-- ------------------------------------------------------------------

SELECT 
    vc.subject_id,
    vc.hadm_id,
    vc.group_type,
    ce.charttime,
    ce.itemid,
    ce.valuenum as map_value,
    CASE 
        WHEN ce.itemid = 220052 THEN 'INVASIVE' -- Arterial Line
        WHEN ce.itemid = 220181 THEN 'NON_INVASIVE' -- NIBP Cuff
        ELSE 'OTHER'
    END as source_type
FROM vascular_cohort vc
INNER JOIN mimiciv_icu.chartevents ce
    ON vc.hadm_id = ce.hadm_id
WHERE 
    ce.itemid IN (220052, 220181) 
    AND ce.valuenum IS NOT NULL
    AND ce.valuenum > 0 AND ce.valuenum < 300 -- Artifact Removal (Coarse)
ORDER BY vc.subject_id, ce.charttime;